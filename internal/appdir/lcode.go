package appdir

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

// LCodeHome is the home folder LCode (a ZCode fork, also a Node/Electron
// app) reads, given home, the user's home as Go reads it (os.UserHomeDir).
// Like ZCode it takes $HOME before os.homedir() on every OS: its data
// folder (getDataBaseDir), settings (resolveUserHomeDir) and the skills it
// reads. On a Mac or Linux that is Go's home too. On Windows Go's is
// USERPROFILE and HOME is mostly unset, but one the user set (for Git
// Bash, MSYS2 or Emacs) is where LCode keeps everything, and magpie would
// otherwise write its provider under USERPROFILE, where LCode never looks
// (the same trap ZCodeHome exists for).
func LCodeHome(home string) string { return LCodeHomeOn(runtime.GOOS, home) }

// LCodeHomeOn is LCodeHome on goos, so a test can ask for Windows'. A HOME
// that isn't rooted is left out. Only the user's own home is moved: a
// folder that isn't USERPROFILE (a test's, a WSL distro's) is LCode's as
// given.
func LCodeHomeOn(goos, home string) string {
	if goos != "windows" {
		return home
	}
	h := strings.TrimSpace(os.Getenv("HOME"))
	if h == "" || !rooted(h) || !strings.EqualFold(filepath.Clean(home), filepath.Clean(os.Getenv("USERPROFILE"))) {
		return home
	}
	return h
}
