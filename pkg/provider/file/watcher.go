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
	return filepath.WalkDir(root, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}

		if !entry.IsDir() && !isFileSupported(entry.Name()) {
			return nil
		}

		log.Debug().Msgf("add watcher on: %s", path)
		if err := watcher.Add(path); err != nil {
			return fmt.Errorf("adding file watcher for %s: %w", path, err)
		}

		return nil
	})
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
