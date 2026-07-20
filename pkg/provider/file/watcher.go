package file

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/fsnotify/fsnotify"
	"github.com/rs/zerolog/log"
)

func addRecursiveFileWatcher(watcher *fsnotify.Watcher, root string) error {
	info, err := os.Stat(root)
	if err != nil {
		return fmt.Errorf("checking file watcher root %s: %w", root, err)
	}

	if !info.IsDir() {
		if !isFileSupported(filepath.Base(root)) {
			return nil
		}

		return addFileWatcher(watcher, root)
	}

	return addRecursiveDirectoryWatcher(watcher, root)
}

func addRecursiveDirectoryWatcher(watcher *fsnotify.Watcher, directory string) error {
	if err := addFileWatcher(watcher, directory); err != nil {
		return err
	}

	entries, err := os.ReadDir(directory)
	if err != nil {
		return fmt.Errorf("reading watched directory %s: %w", directory, err)
	}

	for _, entry := range entries {
		path := filepath.Join(directory, entry.Name())

		if entry.Type()&os.ModeSymlink != 0 {
			if !isFileSupported(entry.Name()) {
				continue
			}

			targetInfo, statErr := os.Stat(path)
			if statErr == nil && targetInfo.IsDir() {
				continue
			}

			if err := addFileWatcher(watcher, path); err != nil {
				return err
			}
			continue
		}

		if entry.IsDir() {
			if err := addRecursiveDirectoryWatcher(watcher, path); err != nil {
				return err
			}
			continue
		}

		if !isFileSupported(entry.Name()) {
			continue
		}

		if err := addFileWatcher(watcher, path); err != nil {
			return err
		}
	}

	return nil
}

func addCreatedDirectoryWatcher(watcher *fsnotify.Watcher, path string, followSymlink bool) error {
	info, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("checking created watcher path %s: %w", path, err)
	}

	if info.Mode()&os.ModeSymlink != 0 {
		if !followSymlink {
			return nil
		}

		info, err = os.Stat(path)
		if err != nil {
			return fmt.Errorf("checking created watcher symlink %s: %w", path, err)
		}
	}

	if !info.IsDir() {
		return nil
	}

	return addRecursiveDirectoryWatcher(watcher, path)
}

func refreshRecursiveFileWatcher(watcher *fsnotify.Watcher, path string, followSymlink bool) error {
	removeErr := removeRecursiveFileWatcher(watcher, path)
	addErr := addCreatedDirectoryWatcher(watcher, path, followSymlink)
	if errors.Is(addErr, os.ErrNotExist) {
		addErr = nil
	}

	return errors.Join(removeErr, addErr)
}

func addFileWatcher(watcher *fsnotify.Watcher, path string) error {
	log.Debug().Msgf("add watcher on: %s", path)
	if err := watcher.Add(path); err != nil {
		return fmt.Errorf("adding file watcher for %s: %w", path, err)
	}

	return nil
}

func removeRecursiveFileWatcher(watcher *fsnotify.Watcher, root string) error {
	var removeErrors []error

	for _, watchedPath := range watcher.WatchList() {
		if !isSameOrDescendantPath(root, watchedPath) {
			continue
		}

		log.Debug().Msgf("remove watcher on: %s", watchedPath)
		if err := watcher.Remove(watchedPath); err != nil && !errors.Is(err, fsnotify.ErrNonExistentWatch) {
			removeErrors = append(removeErrors, fmt.Errorf("removing file watcher for %s: %w", watchedPath, err))
		}
	}

	return errors.Join(removeErrors...)
}

func isSameOrDescendantPath(root, candidate string) bool {
	relativePath, err := filepath.Rel(root, candidate)
	if err != nil {
		return false
	}

	return relativePath == "." || (relativePath != ".." && !strings.HasPrefix(relativePath, ".."+string(os.PathSeparator)))
}

type fileWatcherNotification struct {
	event *fsnotify.Event
	err   error
}

// runFileWatcherOperation keeps draining fsnotify while an operation mutates
// the watch set. The Windows backend can otherwise block Add or Remove while
// delivering events through its bounded channel.
func runFileWatcherOperation(watcher *fsnotify.Watcher, operation func() error) ([]fileWatcherNotification, error) {
	result := make(chan error, 1)
	go func() {
		result <- operation()
	}()

	events := watcher.Events
	errorsChannel := watcher.Errors
	var notifications []fileWatcherNotification

	for {
		select {
		case err := <-result:
			return notifications, err
		case event, ok := <-events:
			if !ok {
				events = nil
				if errorsChannel == nil {
					return notifications, <-result
				}
				continue
			}

			if event.Has(fsnotify.Create) || event.Has(fsnotify.Remove) || event.Has(fsnotify.Rename) {
				eventCopy := event
				notifications = append(notifications, fileWatcherNotification{event: &eventCopy})
			}
		case err, ok := <-errorsChannel:
			if !ok {
				errorsChannel = nil
				if events == nil {
					return notifications, <-result
				}
				continue
			}

			notifications = append(notifications, fileWatcherNotification{err: err})
		}
	}
}
