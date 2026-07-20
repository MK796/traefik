package file

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/fsnotify/fsnotify"
	"github.com/stretchr/testify/require"
	"github.com/traefik/traefik/v3/pkg/config/dynamic"
	"github.com/traefik/traefik/v3/pkg/safe"
)

const fileWatchExhaustionEnv = "TRAEFIK_FILE_WATCH_EXHAUSTION"

func TestProvideWatchExhaustionDeepTree(t *testing.T) {
	requireFileWatchExhaustion(t)

	directory := t.TempDir()
	configurationDirectory := directory
	for i := range 64 {
		configurationDirectory = filepath.Join(configurationDirectory, fmt.Sprintf("level-%02d", i))
	}
	require.NoError(t, os.MkdirAll(configurationDirectory, 0o755))

	configurationFile := filepath.Join(configurationDirectory, "config.yml")
	writeExhaustionConfiguration(t, configurationFile, "before")

	configurationChan := startExhaustionProvider(t, directory)
	waitForExhaustionServices(t, configurationChan, map[string]struct{}{"before": {}}, 30*time.Second)

	for i := range 40 {
		serviceName := fmt.Sprintf("updated_%02d", i)
		writeExhaustionConfiguration(t, configurationFile, serviceName)
		waitForExhaustionServices(t, configurationChan, map[string]struct{}{serviceName: {}}, 30*time.Second)
	}
}

func TestProvideWatchExhaustionBurst(t *testing.T) {
	requireFileWatchExhaustion(t)

	directory := t.TempDir()
	configurationChan := startExhaustionProvider(t, directory)
	waitForExhaustionMessage(t, configurationChan, 30*time.Second)

	const configurationCount = 80
	expectedServices := make(map[string]struct{}, configurationCount)
	configurationFiles := make([]string, 0, configurationCount)

	for i := range configurationCount {
		configurationDirectory := filepath.Join(directory, fmt.Sprintf("group-%02d", i%8), fmt.Sprintf("item-%03d", i), "nested")
		require.NoError(t, os.MkdirAll(configurationDirectory, 0o755))

		serviceName := fmt.Sprintf("created_%03d", i)
		configurationFile := filepath.Join(configurationDirectory, "config.yml")
		writeExhaustionConfiguration(t, configurationFile, serviceName)

		expectedServices[serviceName] = struct{}{}
		configurationFiles = append(configurationFiles, configurationFile)
	}

	waitForExhaustionServices(t, configurationChan, expectedServices, 30*time.Second)

	clear(expectedServices)
	for i, configurationFile := range configurationFiles {
		serviceName := fmt.Sprintf("updated_%03d", i)
		writeExhaustionConfiguration(t, configurationFile, serviceName)
		expectedServices[serviceName] = struct{}{}
	}

	waitForExhaustionServices(t, configurationChan, expectedServices, 30*time.Second)
}

func TestProvideWatchExhaustionAtomicReplacement(t *testing.T) {
	requireFileWatchExhaustion(t)

	directory := t.TempDir()
	configurationDirectory := filepath.Join(directory, "atomic", "nested")
	require.NoError(t, os.MkdirAll(configurationDirectory, 0o755))

	configurationFile := filepath.Join(configurationDirectory, "config.yml")
	writeExhaustionConfiguration(t, configurationFile, "before")

	configurationChan := startExhaustionProvider(t, directory)
	waitForExhaustionServices(t, configurationChan, map[string]struct{}{"before": {}}, 30*time.Second)

	for i := range 40 {
		serviceName := fmt.Sprintf("replacement_%02d", i)
		replaceExhaustionConfiguration(t, configurationFile, serviceName)
		waitForExhaustionServices(t, configurationChan, map[string]struct{}{serviceName: {}}, 30*time.Second)
	}
}

func TestProvideWatchExhaustionRecreate(t *testing.T) {
	requireFileWatchExhaustion(t)

	directory := t.TempDir()
	configurationChan := startExhaustionProvider(t, directory)
	waitForExhaustionMessage(t, configurationChan, 30*time.Second)

	configurationRoot := filepath.Join(directory, "recreated")
	for i := range 40 {
		require.NoError(t, os.RemoveAll(configurationRoot))

		configurationDirectory := filepath.Join(configurationRoot, fmt.Sprintf("generation-%02d", i), "nested")
		require.NoError(t, os.MkdirAll(configurationDirectory, 0o755))

		serviceName := fmt.Sprintf("generation_%02d", i)
		writeExhaustionConfiguration(t, filepath.Join(configurationDirectory, "config.yml"), serviceName)
		waitForExhaustionServices(t, configurationChan, map[string]struct{}{serviceName: {}}, 30*time.Second)
	}
}

func TestRecursiveFileWatcherExhaustionCleanup(t *testing.T) {
	requireFileWatchExhaustion(t)

	directory := t.TempDir()
	persistentDirectory := filepath.Join(directory, "transient-copy", "nested")
	require.NoError(t, os.MkdirAll(persistentDirectory, 0o755))
	writeExhaustionConfiguration(t, filepath.Join(persistentDirectory, "config.yml"), "persistent")

	watcher, err := fsnotify.NewBufferedWatcher(4096)
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, watcher.Close()) })

	require.NoError(t, addRecursiveFileWatcher(watcher, directory))
	baseline := watcher.WatchList()
	require.NotEmpty(t, baseline)

	transientDirectory := filepath.Join(directory, "transient")
	for i := range 100 {
		nestedDirectory := filepath.Join(transientDirectory, fmt.Sprintf("generation-%03d", i), "one", "two", "three")
		require.NoError(t, os.MkdirAll(nestedDirectory, 0o755))

		for j := range 4 {
			writeExhaustionConfiguration(t, filepath.Join(nestedDirectory, fmt.Sprintf("config-%d.yml", j)), fmt.Sprintf("service_%03d_%d", i, j))
		}

		require.NoError(t, addRecursiveFileWatcher(watcher, transientDirectory))
		require.Greater(t, len(watcher.WatchList()), len(baseline))

		require.NoError(t, removeRecursiveFileWatcher(watcher, transientDirectory))
		require.ElementsMatch(t, baseline, watcher.WatchList())
		require.NoError(t, os.RemoveAll(transientDirectory))
	}
}

func TestRecursiveFileWatcherDoesNotFollowDirectorySymlinks(t *testing.T) {
	directory := t.TempDir()
	externalDirectory := t.TempDir()
	require.NoError(t, os.MkdirAll(filepath.Join(externalDirectory, "nested"), 0o755))

	symlinkPath := filepath.Join(directory, "external.yml")
	if err := os.Symlink(externalDirectory, symlinkPath); err != nil {
		t.Skipf("creating directory symlinks is not supported: %v", err)
	}

	watcher, err := fsnotify.NewWatcher()
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, watcher.Close()) })

	require.NoError(t, addRecursiveFileWatcher(watcher, directory))
	require.NotContains(t, watcher.WatchList(), symlinkPath)
	require.NotContains(t, watcher.WatchList(), filepath.Join(externalDirectory, "nested"))
}

func TestRecursiveFileWatcherWatchesFileSymlinks(t *testing.T) {
	directory := t.TempDir()
	targetDirectory := t.TempDir()
	targetPath := filepath.Join(targetDirectory, "target.yml")
	require.NoError(t, os.WriteFile(targetPath, []byte(exhaustionConfiguration("target")), 0o644))

	symlinkPath := filepath.Join(directory, "config.yml")
	if err := os.Symlink(targetPath, symlinkPath); err != nil {
		t.Skipf("creating file symlinks is not supported: %v", err)
	}

	watcher, err := fsnotify.NewWatcher()
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, watcher.Close()) })

	require.NoError(t, addRecursiveFileWatcher(watcher, directory))
	require.Contains(t, watcher.WatchList(), symlinkPath)
}

func TestRecursiveFileWatcherReportsSupportedDanglingSymlinks(t *testing.T) {
	directory := t.TempDir()
	symlinkPath := filepath.Join(directory, "dangling.yml")
	if err := os.Symlink(filepath.Join(directory, "missing.yml"), symlinkPath); err != nil {
		t.Skipf("creating file symlinks is not supported: %v", err)
	}

	watcher, err := fsnotify.NewWatcher()
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, watcher.Close()) })

	err = addRecursiveFileWatcher(watcher, directory)
	require.Error(t, err)
	require.ErrorContains(t, err, symlinkPath)
}

func TestRecursiveFileWatcherIgnoresUnsupportedFiles(t *testing.T) {
	directory := t.TempDir()
	for i := range 1000 {
		require.NoError(t, os.WriteFile(filepath.Join(directory, fmt.Sprintf("ignored-%04d.txt", i)), []byte("ignored"), 0o644))
	}

	watcher, err := fsnotify.NewWatcher()
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, watcher.Close()) })

	require.NoError(t, addRecursiveFileWatcher(watcher, directory))
	require.Equal(t, []string{directory}, watcher.WatchList())
}

func requireFileWatchExhaustion(t *testing.T) {
	t.Helper()

	if os.Getenv(fileWatchExhaustionEnv) == "" {
		t.Skipf("set %s to run file watcher exhaustion tests", fileWatchExhaustionEnv)
	}
}

func startExhaustionProvider(t *testing.T, directory string) chan dynamic.Message {
	t.Helper()

	configurationChan := make(chan dynamic.Message, 4096)
	provider := &Provider{Directory: directory, Watch: true}
	pool := safe.NewPool(t.Context())
	t.Cleanup(pool.Stop)
	require.NoError(t, provider.Provide(configurationChan, pool))

	return configurationChan
}

func writeExhaustionConfiguration(t *testing.T, filename, serviceName string) {
	t.Helper()

	require.NoError(t, os.WriteFile(filename, []byte(exhaustionConfiguration(serviceName)), 0o644))
}

func replaceExhaustionConfiguration(t *testing.T, filename, serviceName string) {
	t.Helper()

	temporaryFile, err := os.CreateTemp(filepath.Dir(filename), ".replacement-*.yml")
	require.NoError(t, err)
	temporaryName := temporaryFile.Name()
	t.Cleanup(func() { _ = os.Remove(temporaryName) })

	_, err = temporaryFile.WriteString(exhaustionConfiguration(serviceName))
	require.NoError(t, err)
	require.NoError(t, temporaryFile.Close())

	backupName := filename + ".backup"
	_ = os.Remove(backupName)
	require.NoError(t, os.Rename(filename, backupName))
	require.NoError(t, os.Rename(temporaryName, filename))
	require.NoError(t, os.Remove(backupName))
}

func exhaustionConfiguration(serviceName string) string {
	return fmt.Sprintf(`http:
  services:
    %s:
      loadBalancer:
        servers:
          - url: http://127.0.0.1
`, serviceName)
}

func waitForExhaustionServices(t *testing.T, configurationChan <-chan dynamic.Message, expectedServices map[string]struct{}, waitTimeout time.Duration) {
	t.Helper()

	timeout := time.NewTimer(waitTimeout)
	defer timeout.Stop()

	for {
		select {
		case message := <-configurationChan:
			if message.Configuration == nil || message.Configuration.HTTP == nil {
				continue
			}

			matched := true
			for serviceName := range expectedServices {
				if _, ok := message.Configuration.HTTP.Services[serviceName]; !ok {
					matched = false
					break
				}
			}
			if matched {
				return
			}
		case <-timeout.C:
			t.Fatalf("timeout while waiting for %d services", len(expectedServices))
		}
	}
}

func waitForExhaustionMessage(t *testing.T, configurationChan <-chan dynamic.Message, waitTimeout time.Duration) dynamic.Message {
	t.Helper()

	select {
	case message := <-configurationChan:
		return message
	case <-time.After(waitTimeout):
		t.Fatal("timeout while waiting for file provider configuration")
		return dynamic.Message{}
	}
}
