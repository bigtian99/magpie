package gateway

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// restsFile is where the rests survive a restart.
//
// restingUntil is a map in memory: an account refused as out of quota rests
// for as long as the vendor said, a key rate limited rests a minute, and
// every one of those was lost the moment magpie stopped. The next start
// knew nothing of them, so the first request after a restart asked the same
// account that had just refused it, and was refused again — the account
// rested for nothing, and the restart looked like it had reset its allowance
// (which, for a vendor that counts by the hour, it had not).
//
// The file is beside providers.json, written when a rest is set or lifted
// and read once at start. A rest that has already ended by then is dropped,
// and one whose time is more than restMaxAhead away is taken as a clock that
// moved, not a rest.
const restsFile = "rests.json"

// restMaxAhead is the longest a rest may still be in the future when read
// back. A vendor's own reset time is the longest magpie keeps (a week's
// window), so anything past this is a clock that went wrong, not a rest.
const restMaxAhead = 30 * 24 * time.Hour

// restsOnDisk is what the file holds: each rest by the key it rests by,
// with the fields the picker and the next rest need.
type restsOnDisk struct {
	Rests map[string]Rest `json:"rests"`
	// At is when this was written, for a clock that moved backwards.
	At time.Time `json:"at"`
}

var (
	restsMu   sync.Mutex
	restsPath string
	// restsSaveEvery is how long a change waits before it is written: rests
	// are set in bursts (one refusal, then the next account's), and a write
	// per refusal would be one file write per failed request.
	restsSaveEvery = 500 * time.Millisecond
	restsSaveTimer *time.Timer
)

// restsChanged asks for restingUntil to be written, at most once per
// restsSaveEvery. The caller holds restingUntil's lock.
func restsChanged() {
	restsMu.Lock()
	path := restsPath
	restsMu.Unlock()
	if path == "" {
		return
	}
	restsMu.Lock()
	if restsSaveTimer == nil {
		restsSaveTimer = time.AfterFunc(restsSaveEvery, func() {
			restsMu.Lock()
			restsSaveTimer = nil
			restsMu.Unlock()
			restsSave()
		})
	}
	restsMu.Unlock()
}

// restsFlush writes any pending change now, for a shutdown that would
// otherwise lose the last rest of a run.
func restsFlush() {
	restsMu.Lock()
	t := restsSaveTimer
	restsSaveTimer = nil
	restsMu.Unlock()
	if t != nil {
		t.Stop()
	}
	restsSave()
}

// restsWhere sets the file the rests are kept in, and reads what is there.
// Called once, before the gateway serves anything.
func restsWhere(dir string) {
	restsMu.Lock()
	restsPath = filepath.Join(dir, restsFile)
	restsMu.Unlock()
	restsLoad()
}

// restsLoad reads the file into restingUntil, dropping what has ended.
func restsLoad() {
	restsMu.Lock()
	path := restsPath
	restsMu.Unlock()
	if path == "" {
		return
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var d restsOnDisk
	if json.Unmarshal(b, &d) != nil || len(d.Rests) == 0 {
		return
	}
	now := time.Now()
	restingUntil.Lock()
	for key, r := range d.Rests {
		// a rest that ended while magpie was down is no rest
		if !r.Until.After(now) {
			continue
		}
		// and one absurdly far off is a clock that moved, not a rest
		if r.Until.Sub(now) > restMaxAhead {
			continue
		}
		// what this computer found still stands: a file written elsewhere
		// never shortens a rest this process already set
		if was, ok := restingUntil.m[key]; ok && was.After(r.Until) {
			continue
		}
		restingUntil.m[key] = r.Until
		restingUntil.note[key] = r
	}
	restingUntil.Unlock()
}

// restsSave writes restingUntil to the file, dropping what has ended.
// Called with restingUntil unlocked, after a change.
func restsSave() {
	restsMu.Lock()
	path := restsPath
	restsMu.Unlock()
	if path == "" {
		return
	}
	now := time.Now()
	restingUntil.Lock()
	out := restsOnDisk{Rests: make(map[string]Rest, len(restingUntil.m)), At: now}
	for key, until := range restingUntil.m {
		if !until.After(now) {
			continue
		}
		out.Rests[key] = restingUntil.note[key]
	}
	restingUntil.Unlock()
	b, err := json.Marshal(out)
	if err != nil {
		return
	}
	// a write that fails costs the next restart its rests, never this run's
	if tmp, err := os.CreateTemp(filepath.Dir(path), restsFile+".*"); err == nil {
		if _, err := tmp.Write(b); err == nil && tmp.Close() == nil {
			if os.Rename(tmp.Name(), path) == nil {
				return
			}
		}
		tmp.Close()
		os.Remove(tmp.Name())
	}
	os.WriteFile(path, b, 0o600)
}
