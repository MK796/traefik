package file

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"github.com/traefik/traefik/v3/pkg/config/dynamic"
	"github.com/traefik/traefik/v3/pkg/safe"
)

func TestProvideWatchRecursively(t *testing.T) {
	t.Run("existing subdirectory", func(t *testing.T) {
		directory := t.TempDir()
		configurationFile := filepath.Join(directory, "existing", "nested", "config.yml")

		require.NoError(t, os.MkdirAll(filepath.Dir(configurationFile), 0o755))
		writeWatchConfiguration(t, configurationFile, "before")

		configurationChan := startWatchedDirectoryProvider(t, directory)
		waitForService(t, configurationChan, "before")

		writeWatchConfiguration(t, configurationFile, "after")
		waitForService(t, configurationChan, "after")
	})

	t.Run("new subdirectory", func(t *testing.T) {
		directory := t.TempDir()
		configurationChan := startWatchedDirectoryProvider(t, directory)
		waitForFileProviderMessage(t, configurationChan)

		configurationDirectory := filepath.Join(directory, "created")
		require.NoError(t, os.Mkdir(configurationDirectory, 0o755))
		waitForFileProviderMessage(t, configurationChan)

		configurationFile := filepath.Join(configurationDirectory, "config.yml")
		writeWatchConfiguration(t, configurationFile, "created")
		waitForService(t, configurationChan, "created")
	})

	t.Run("renamed directory tree", func(t *testing.T) {
		baseDirectory := t.TempDir()
		directory := filepath.Join(baseDirectory, "watched")
		stagingDirectory := filepath.Join(baseDirectory, "staging")
		configurationFile := filepath.Join(stagingDirectory, "nested", "config.yml")

		require.NoError(t, os.Mkdir(directory, 0o755))
		require.NoError(t, os.MkdirAll(filepath.Dir(configurationFile), 0o755))
		writeWatchConfiguration(t, configurationFile, "before")

		configurationChan := startWatchedDirectoryProvider(t, directory)
		waitForFileProviderMessage(t, configurationChan)

		importedDirectory := filepath.Join(directory, "imported")
		require.NoError(t, os.Rename(stagingDirectory, importedDirectory))
		waitForService(t, configurationChan, "before")

		configurationFile = filepath.Join(importedDirectory, "nested", "config.yml")
		writeWatchConfiguration(t, configurationFile, "after")
		waitForService(t, configurationChan, "after")
	})

	t.Run("recreated subdirectory", func(t *testing.T) {
		directory := t.TempDir()
		configurationDirectory := filepath.Join(directory, "recreated")
		configurationFile := filepath.Join(configurationDirectory, "config.yml")

		require.NoError(t, os.Mkdir(configurationDirectory, 0o755))
		writeWatchConfiguration(t, configurationFile, "before")

		configurationChan := startWatchedDirectoryProvider(t, directory)
		waitForService(t, configurationChan, "before")

		// Windows can transiently report a sharing violation while fsnotify
		// finishes delivering events for the watched directory.
		requireEventuallyNoError(t, func() error {
			return os.RemoveAll(configurationDirectory)
		})
		waitForMissingService(t, configurationChan, "before")

		require.NoError(t, os.Mkdir(configurationDirectory, 0o755))
		writeWatchConfiguration(t, configurationFile, "recreated")
		waitForService(t, configurationChan, "recreated")

		writeWatchConfiguration(t, configurationFile, "after")
		waitForService(t, configurationChan, "after")
	})

	t.Run("symlinked root", func(t *testing.T) {
		baseDirectory := t.TempDir()
		realDirectory := filepath.Join(baseDirectory, "real")
		configurationFile := filepath.Join(realDirectory, "nested", "config.yml")

		require.NoError(t, os.MkdirAll(filepath.Dir(configurationFile), 0o755))
		writeWatchConfiguration(t, configurationFile, "before")

		symlinkDirectory := filepath.Join(baseDirectory, "watched")
		if err := os.Symlink(realDirectory, symlinkDirectory); err != nil {
			t.Skipf("creating directory symlinks is not supported: %v", err)
		}

		configurationChan := startWatchedDirectoryProvider(t, symlinkDirectory)
		waitForService(t, configurationChan, "before")

		writeWatchConfiguration(t, configurationFile, "after")
		waitForService(t, configurationChan, "after")
	})
}

func startWatchedDirectoryProvider(t *testing.T, directory string) chan dynamic.Message {
	t.Helper()

	configurationChan := make(chan dynamic.Message, 32)
	provider := &Provider{Directory: directory, Watch: true}
	pool := safe.NewPool(t.Context())
	t.Cleanup(pool.Stop)

	require.NoError(t, provider.Provide(configurationChan, pool))

	return configurationChan
}

func writeWatchConfiguration(t *testing.T, filename, serviceName string) {
	t.Helper()

	configuration := fmt.Sprintf(`http:
  services:
    %s:
      loadBalancer:
        servers:
          - url: http://127.0.0.1
`, serviceName)
	require.NoError(t, os.WriteFile(filename, []byte(configuration), 0o644))
}

func waitForService(t *testing.T, configurationChan <-chan dynamic.Message, serviceName string) {
	t.Helper()

	timeout := time.NewTimer(3 * time.Second)
	defer timeout.Stop()

	for {
		select {
		case message := <-configurationChan:
			if message.Configuration == nil || message.Configuration.HTTP == nil {
				continue
			}

			if _, ok := message.Configuration.HTTP.Services[serviceName]; ok {
				return
			}
		case <-timeout.C:
			t.Fatalf("timeout while waiting for service %q", serviceName)
		}
	}
}

func waitForMissingService(t *testing.T, configurationChan <-chan dynamic.Message, serviceName string) {
	t.Helper()

	timeout := time.NewTimer(3 * time.Second)
	defer timeout.Stop()

	for {
		select {
		case message := <-configurationChan:
			if message.Configuration == nil || message.Configuration.HTTP == nil {
				return
			}

			if _, ok := message.Configuration.HTTP.Services[serviceName]; !ok {
				return
			}
		case <-timeout.C:
			t.Fatalf("timeout while waiting for service %q to be removed", serviceName)
		}
	}
}

func waitForFileProviderMessage(t *testing.T, configurationChan <-chan dynamic.Message) dynamic.Message {
	t.Helper()

	select {
	case message := <-configurationChan:
		return message
	case <-time.After(3 * time.Second):
		t.Fatal("timeout while waiting for file provider configuration")
		return dynamic.Message{}
	}
}
