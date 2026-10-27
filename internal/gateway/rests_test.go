package gateway

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)


// restsReset clears the global map and points the file at dir, for a test
// that starts as a fresh process would.
func restsReset(t *testing.T, dir string) {
	t.Helper()
	restingUntil.Lock()
	restingUntil.m = map[string]time.Time{}
	restingUntil.note = map[string]Rest{}
	restingUntil.lifted = map[string]time.Time{}
	restingUntil.Unlock()
	restsMu.Lock()
	restsSaveTimer = nil
	restsMu.Unlock()
	restsWhere(dir)
}

// restAfterReset is what a test does to look like a new process.
func restAfterReset(t *testing.T, dir string) {
	t.Helper()
	restingUntil.Lock()
	restingUntil.m = map[string]time.Time{}
	restingUntil.note = map[string]Rest{}
	restingUntil.Unlock()
	restsWhere(dir)
}

// restingUntil is a map in memory, so a restart used to forget every rest:
// the first request after one asked the account that had just refused it.
// These hold the file that carries them across.
func TestRestsSurviveARestart(t *testing.T) {
	dir := t.TempDir()
	restsReset(t, dir)

	// an account out of quota until an hour from now
	until := time.Now().Add(time.Hour).Truncate(time.Second)
	restingUntil.Lock()
	restingUntil.m["zcode"] = until
	restingUntil.note["zcode"] = Rest{Why: failQuota, Status: 429, By: "quota", Key: "zcode", Until: until}
	restsChanged()
	restingUntil.Unlock()

	restsFlush()

	// a new process: the map starts empty
	restAfterReset(t, dir)

	restingUntil.Lock()
	got, ok := restingUntil.m["zcode"]
	why := restingUntil.note["zcode"].Why
	restingUntil.Unlock()
	if !ok {
		t.Fatal("the rest did not survive: zcode is not resting after a restart")
	}
	if !got.Equal(until) {
		t.Fatalf("the rest ends at %v, want %v", got, until)
	}
	if why != failQuota {
		t.Fatalf("the rest's why is %q, want %q", why, failQuota)
	}
}

// A rest that ended while magpie was down is no rest: the account may be
// asked at once.
func TestAnEndedRestIsNotLoaded(t *testing.T) {
	dir := t.TempDir()
	restsReset(t, dir)

	past := time.Now().Add(-time.Minute)
	restingUntil.Lock()
	restingUntil.m["old"] = past
	restingUntil.note["old"] = Rest{Why: failQuota, Status: 429, By: "quota", Key: "old", Until: past}
	restsChanged()
	restingUntil.Unlock()
	restsFlush()

	restAfterReset(t, dir)

	restingUntil.Lock()
	_, ok := restingUntil.m["old"]
	restingUntil.Unlock()
	if ok {
		t.Fatal("a rest that ended before the restart is still resting")
	}
}

// A rest absurdly far in the future is a clock that moved, not a rest: the
// account would be benched for years.
func TestARestPastTheLongestWindowIsDropped(t *testing.T) {
	dir := t.TempDir()
	restsReset(t, dir)

	far := time.Now().Add(restMaxAhead + time.Hour)
	restingUntil.Lock()
	restingUntil.m["clock"] = far
	restingUntil.note["clock"] = Rest{Why: failQuota, Status: 429, By: "quota", Key: "clock", Until: far}
	restsChanged()
	restingUntil.Unlock()
	restsFlush()

	restAfterReset(t, dir)

	restingUntil.Lock()
	_, ok := restingUntil.m["clock"]
	restingUntil.Unlock()
	if ok {
		t.Fatal("a rest 30 days out was loaded: a clock that moved benches an account for years")
	}
}

// Lifting a rest writes that too, so a restart doesn't bring it back.
func TestALiftedRestStaysLifted(t *testing.T) {
	dir := t.TempDir()
	restsReset(t, dir)

	until := time.Now().Add(time.Hour)
	restingUntil.Lock()
	restingUntil.m["lift"] = until
	restingUntil.note["lift"] = Rest{Why: failQuota, Status: 429, By: "quota", Key: "lift", Until: until}
	restsChanged()
	restingUntil.Unlock()
	restsFlush()

	(&Server{}).Unrest("lift")
	restsFlush()

	restAfterReset(t, dir)

	restingUntil.Lock()
	_, ok := restingUntil.m["lift"]
	restingUntil.Unlock()
	if ok {
		t.Fatal("a lifted rest came back after a restart")
	}
}

// No file, no rests: a first start must not fail.
func TestRestsWithoutAFile(t *testing.T) {
	dir := t.TempDir()
	restsReset(t, dir)
	restingUntil.Lock()
	n := len(restingUntil.m)
	restingUntil.Unlock()
	if n != 0 {
		t.Fatalf("a fresh folder left %d rests", n)
	}
	if _, err := os.Stat(filepath.Join(dir, restsFile)); err == nil {
		t.Fatal("loading wrote a file; only a change should")
	}
}
