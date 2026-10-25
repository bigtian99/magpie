package agent

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"

	"github.com/yetone/magpie/internal/appdir"
	"github.com/yetone/magpie/internal/edit"
	"github.com/yetone/magpie/internal/gateway"
)

// LCode (Zhipu's desktop app) keeps its model providers in
// ~/.lcode/v2/config.json (under the folder the user moved its data to, when
// they did: appdir.LCodeDataIn), OpenCode's provider shape with a kind of its own:
//
//	{"provider":{"magpie":{"name":"magpie","kind":"anthropic",
//	  "options":{"apiKey":"magpie","baseURL":"http://127.0.0.1:3425"},
//	  "enabled":true,"source":"custom",
//	  "models":{"<id>":{"name":…,"limit":{"context":…,"output":…},"modalities":{…},
//	    "reasoning":{"enabled":true,"variants":[…],"defaultVariant":…}}}}}}
//
// An anthropic provider is asked at baseURL + /v1/messages. The model is
// picked per task in LCode's own picker and kept in its window, not in a
// file, so what magpie sets is whether its models are in that picker.
//
// LCode 3.14 moved its providers to ~/.lcode/v2/provider_config.json and
// reads config.json's only once, to import them, so a provider added there
// later never reached its picker. There a provider is a rule, and a model's
// context window and inputs are rules of their own:
//
//	{"schemaVersion":1,"config":{
//	  "providerConfigRules":{"providerRules":[{"providerId":"magpie",
//	    "providerName":"magpie","enabled":true,"config":{
//	      "group":"standard-personal",
//	      "access":{"type":"api-key","apiKey":"magpie"},
//	      "api":{"type":"anthropic-messages","baseUrl":"http://127.0.0.1:3425"},
//	      "personalModelIds":[…],"modelOrder":[…]}}]},
//	  "modelConfigRules":{"providerModelRules":[{"providerId":"magpie",
//	    "modelId":…,"config":{"properties":{"contextWindow":…,
//	      "inputFormat":{"supportsImage":…},"supportsNativeWebSearch":true},
//	      "optionSpecs":{"maxOutputTokens":{"max":…},"reasoningLevel":{"values":[…]}}}}],
//	    "manualProviderModelRules":[…]}}}
//
// magpie writes both files, so an older LCode sees its models too. A model
// the user set by hand in LCode (a manual rule) keeps what they set.
//
// magpie's gateway answers all three of LCode's API formats at the same
// address (/v1/messages, /chat/completions, /responses), so the format the
// user picked in LCode's provider settings is theirs: a sync keeps it in both
// files (lcodeFormat), and only a provider magpie adds new starts on
// Anthropic Messages.

// lcodeOS is the OS LCode's home is found for, so a test can ask for
// Windows' (appdir.LCodeHomeOn).
var lcodeOS = runtime.GOOS

func lcode(home string) *Agent {
	// where LCode keeps its data: ~/.lcode under the home LCode reads (HOME
	// first, on Windows too). LCode has no "data storage path" setting of
	// its own, so the folder is always the home's.
	dir := filepath.Join(appdir.LCodeHomeOn(lcodeOS, home), ".lcode")
	path := filepath.Join(dir, "v2", "config.json")
	rules := filepath.Join(dir, "v2", "provider_config.json")
	key := "provider." + magpieID
	wired := func() bool {
		_, ok := edit.GetJSON(path, key)
		return ok || lcodeRuled(rules)
	}
	return &Agent{
		ID: "lcode", Name: "LCode", Icon: "lcode", Aliases: []string{"l-code"},
		UA:  []string{"lcode"},
		Dir: dir, Path: path,
		// its picker lists the models picked for it, in both files (#1508)
		ListsModels: true,
		Notice: func() string {
			if Running(`LCode\.app/`, `(^|/)LCode( |$)`) {
				return noticeLcode.String()
			}
			return ""
		},
		Sync: func() error {
			if !wired() {
				return nil
			}
			// a LCode that keeps its providers as rules, with magpie's taken
			// out there, had it removed in LCode: it isn't put back
			if _, err := os.Stat(rules); err != nil || lcodeRuled(rules) {
				if err := lcodeRules(rules, true, true); err != nil {
					return err
				}
			}
			return edit.SetJSON(path, edit.KV{Path: key, Value: lcodeProviderJSON(path, true)})
		},
		Fields: []Field{{
			Key: "provider", Label: "provider",
			Get: func() string {
				if wired() {
					return magpieID
				}
				return ""
			},
			Set: func(v string) error {
				if err := lcodeRules(rules, v != "", false); err != nil {
					return err
				}
				if v == "" {
					if _, ok := stashLoad()[lcodeSearchedKey]; ok {
						forget(lcodeSearchedKey)
					}
					return edit.DelJSON(path, key)
				}
				return edit.SetJSON(path, edit.KV{Path: key, Value: lcodeProviderJSON(path, false)})
			},
			Options: func(map[string]string) []Option {
				return []Option{{Value: magpieID, Label: "magpie", Icon: "magpie", Note: "every magpie model in LCode's picker"}}
			},
		}},
	}
}

// lcodeProviderJSON is magpie's provider in config.json at path; one
// turned off in LCode stays off. A sync (keep) leaves an address on another
// machine as it found it (lcodeAddress).
func lcodeProviderJSON(path string, keep bool) any {
	was := lcodeVariants(path)
	ms := map[string]any{}
	for _, m := range magpieModels("lcode") {
		window := m.Context
		if window == 0 {
			window = 200000
		}
		in := []string{"text"}
		if m.Images {
			in = append(in, "image")
		}
		limit := map[string]any{"context": window}
		// without it LCode caps every reply at 32000 tokens
		if out := outputOr(m, lcodeOutput(maxTokens(m))); out > 0 {
			limit["output"] = out
		}
		e := map[string]any{"name": m.Name, "limit": limit,
			"modalities": map[string]any{"input": in, "output": []string{"text"}}}
		if levels := lcodeLevels(m.Efforts); levels != nil {
			e["reasoning"] = map[string]any{"enabled": true, "variants": levels, "defaultVariant": keptEffort(was[m.ID], levels, lcodeDefaultLevel(levels))}
		}
		ms[m.ID] = e
	}
	on := true
	if v, ok := edit.GetJSON(path, "provider."+magpieID+".enabled"); ok && v == "false" {
		on = false
	}
	base, token := gateway.URL(), hereKey()
	if keep {
		base, token = lcodeKept(filepath.Dir(path))
	}
	return map[string]any{"name": "magpie", "kind": lcodeKinds[lcodeFormat(filepath.Dir(path))], "enabled": on, "source": "custom",
		"options": map[string]any{"apiKey": token, "baseURL": base}, "models": ms}
}

// lcodeVariants is the default variant each of magpie's models has in
// config.json at path, which one set by hand keeps (keptEffort).
func lcodeVariants(path string) map[string]string {
	var c struct {
		Provider map[string]struct {
			Models map[string]struct {
				Reasoning struct {
					DefaultVariant string `json:"defaultVariant"`
				} `json:"reasoning"`
			} `json:"models"`
		} `json:"provider"`
	}
	b, _ := edit.Read(path)
	if json.Unmarshal(b, &c) != nil {
		return nil
	}
	out := map[string]string{}
	for id, m := range c.Provider[magpieID].Models {
		out[id] = m.Reasoning.DefaultVariant
	}
	return out
}

// lcodeAddress is the address and key magpie's provider is synced with:
// the gateway's, unless the user pointed the provider at a magpie on another
// machine (a NAS's), which a sync, there to bring the models up to date,
// keeps with its key. An address on this machine's loopback is magpie's own
// and follows the gateway.
func lcodeAddress(was, wasKey string) (string, string) {
	if !onAnotherMachine(was) || sameGateway(was, gateway.URL()) {
		return gateway.URL(), hereKey()
	}
	if wasKey == "" {
		wasKey = gateway.Token
	}
	return was, wasKey
}

// lcodeKept is the address a sync gives magpie's provider in both of
// LCode's files in dir: one on another machine found in either file, so an
// edit LCode made to one of them is carried to the other (LCode's own
// settings write provider_config.json, and a config.json left on this
// machine's magpie took the provider back there), else the gateway's.
func lcodeKept(dir string) (string, string) {
	var r struct {
		Config struct {
			ProviderConfigRules struct {
				ProviderRules []struct {
					ProviderID string `json:"providerId"`
					Config     struct {
						Access struct {
							APIKey string `json:"apiKey"`
						} `json:"access"`
						API struct {
							BaseURL string `json:"baseUrl"`
						} `json:"api"`
					} `json:"config"`
				} `json:"providerRules"`
			} `json:"providerConfigRules"`
		} `json:"config"`
	}
	b, _ := os.ReadFile(filepath.Join(dir, "provider_config.json"))
	json.Unmarshal(b, &r)
	for _, p := range r.Config.ProviderConfigRules.ProviderRules {
		if p.ProviderID == magpieID && onAnotherMachine(p.Config.API.BaseURL) {
			return lcodeAddress(p.Config.API.BaseURL, p.Config.Access.APIKey)
		}
	}
	path := filepath.Join(dir, "config.json")
	was, _ := edit.GetJSON(path, "provider."+magpieID+".options.baseURL")
	wasKey, _ := edit.GetJSON(path, "provider."+magpieID+".options.apiKey")
	return lcodeAddress(was, wasKey)
}

// lcodeKinds are LCode's API formats in provider_config.json (api.type) and
// the kind each is in config.json, as LCode maps one to the other.
var lcodeKinds = map[string]string{
	"anthropic-messages":      "anthropic",
	"openai-chat-completions": "openai-compatible",
	"openai-responses":        "openai",
}

// lcodeFormat is the API format magpie's provider has in LCode's files in
// dir: the one the user picked in LCode's settings, else Anthropic Messages.
// magpie writes both files together, so where they differ the user changed
// one of them in LCode (provider_config.json from 3.14 on, config.json
// before): the one written last has their choice, which is carried to the
// other.
func lcodeFormat(dir string) string {
	rules, kind := lcodeRuleFormat(dir), ""
	path := filepath.Join(dir, "config.json")
	if k, _ := edit.GetJSON(path, "provider."+magpieID+".kind"); k != "" {
		for f, fk := range lcodeKinds {
			if fk == k {
				kind = f
			}
		}
	}
	switch {
	case kind == "" && rules == "":
		return "anthropic-messages"
	case kind == "":
		return rules
	case rules == "" || rules == kind:
		return kind
	}
	a, errA := os.Stat(filepath.Join(dir, "provider_config.json"))
	b, errB := os.Stat(path)
	if errA == nil && errB == nil && b.ModTime().After(a.ModTime()) {
		return kind
	}
	return rules
}

// lcodeRuleFormat is magpie's provider's API format in provider_config.json
// in dir, or "" when it has none LCode knows.
func lcodeRuleFormat(dir string) string {
	var r struct {
		Config struct {
			ProviderConfigRules struct {
				ProviderRules []struct {
					ProviderID string `json:"providerId"`
					Config     struct {
						API struct {
							Type string `json:"type"`
						} `json:"api"`
					} `json:"config"`
				} `json:"providerRules"`
			} `json:"providerConfigRules"`
		} `json:"config"`
	}
	b, _ := os.ReadFile(filepath.Join(dir, "provider_config.json"))
	json.Unmarshal(b, &r)
	for _, p := range r.Config.ProviderConfigRules.ProviderRules {
		if _, ok := lcodeKinds[p.Config.API.Type]; ok && p.ProviderID == magpieID {
			return p.Config.API.Type
		}
	}
	return ""
}

// lcodeMaxOutput caps a model's output limit: some vendors report their
// context window there (grok's 500000), and LCode would offer that much.
const lcodeMaxOutput = 128000

func lcodeOutput(n int) int { return min(n, lcodeMaxOutput) }

// lcodeLevels are a model's reasoning levels as LCode names them: "disabled"
// turns thinking off, any other is sent as the effort.
func lcodeLevels(efforts []string) []string {
	var out []string
	for _, e := range efforts {
		if e == "none" {
			e = "disabled"
		}
		if !slices.Contains(out, e) {
			out = append(out, e)
		}
	}
	return out
}

// lcodeDefaultLevel is medium where the model has it, else its middle level
// that thinks.
func lcodeDefaultLevel(levels []string) string {
	if slices.Contains(levels, "medium") {
		return "medium"
	}
	on := slices.DeleteFunc(slices.Clone(levels), func(l string) bool { return l == "disabled" })
	if len(on) == 0 {
		return levels[0]
	}
	return on[len(on)/2]
}

// lcodeRuled reports whether provider_config.json has magpie's provider.
func lcodeRuled(path string) bool {
	var c struct {
		Config struct {
			ProviderConfigRules struct {
				ProviderRules []struct {
					ProviderID string `json:"providerId"`
				} `json:"providerRules"`
			} `json:"providerConfigRules"`
		} `json:"config"`
	}
	b, _ := os.ReadFile(path)
	if json.Unmarshal(b, &c) != nil {
		return false
	}
	for _, r := range c.Config.ProviderConfigRules.ProviderRules {
		if r.ProviderID == magpieID {
			return true
		}
	}
	return false
}

// lcodeRules puts magpie's provider and its models' rules into LCode's
// provider_config.json (on) or takes them out, leaving every other rule and
// key as LCode wrote it. A sync (keep) leaves an address on another machine
// as it found it (lcodeAddress).
func lcodeRules(path string, on, keep bool) error {
	b, err := edit.Read(path)
	if err != nil {
		return err
	}
	if b == nil && !on {
		return nil
	}
	doc := map[string]any{}
	if len(b) > 0 {
		if err := json.Unmarshal(b, &doc); err != nil {
			return err
		}
	}
	if doc["schemaVersion"] == nil {
		doc["schemaVersion"] = 1
	}
	cfg := lcodeObj(doc, "config")
	pcr := lcodeObj(cfg, "providerConfigRules")
	mcr := lcodeObj(cfg, "modelConfigRules")
	mine := func(r any) bool { m, _ := r.(map[string]any); return m != nil && m["providerId"] == magpieID }

	var old map[string]any
	var providers []any
	at := -1 // where magpie's was, which it keeps
	for _, r := range lcodeList(pcr, "providerRules") {
		if mine(r) {
			old, _ = r.(map[string]any)
			at = len(providers)
			continue
		}
		providers = append(providers, r)
	}
	var models, manual []any
	byHand := map[any]bool{}
	for _, r := range lcodeList(mcr, "manualProviderModelRules") {
		if mine(r) {
			if !on {
				continue
			}
			byHand[r.(map[string]any)["modelId"]] = true
		}
		manual = append(manual, r)
	}
	// magpie's model rules as they are now, which LCode's own settings
	// write a model's edits into while it keeps its recommended config
	ours := map[any]map[string]any{}
	for _, r := range lcodeList(mcr, "providerModelRules") {
		if !mine(r) {
			models = append(models, r)
			continue
		}
		m := r.(map[string]any)
		ours[m["modelId"]] = m
	}

	if on {
		format := lcodeFormat(filepath.Dir(path))
		searched, known := lcodeSearched()
		var ids []string
		for _, m := range magpieModels("lcode") {
			ids = append(ids, m.ID)
			if byHand[m.ID] {
				// set by hand in LCode: its own settings, and the default
				// again should it go back to its recommended config
				delete(searched, m.ID)
				continue
			}
			props := map[string]any{"inputFormat": map[string]any{"supportsImage": m.Images}}
			if m.Context > 0 {
				props["contextWindow"] = m.Context
			}
			if v, set := lcodeWebSearch(ours[m.ID], m.ID, format == "anthropic-messages" && known, searched); set {
				props["supportsNativeWebSearch"] = v
			}
			config := map[string]any{"properties": props}
			// LCode's own rules give a model it doesn't know 32000 tokens
			// out and thinking only on or off
			specs := map[string]any{}
			if out := outputOr(m, lcodeOutput(maxTokens(m))); out > 0 {
				specs["maxOutputTokens"] = map[string]any{"max": out}
			}
			if levels := lcodeLevels(m.Efforts); levels != nil {
				specs["reasoningLevel"] = map[string]any{"values": levels}
			}
			if len(specs) > 0 {
				config["optionSpecs"] = specs
			}
			models = append(models, map[string]any{"providerId": magpieID, "modelId": m.ID, "config": config})
		}
		if ids == nil {
			ids = []string{}
		}
		if known {
			lcodeSearchedPut(searched, ids)
		}
		base, token := gateway.URL(), hereKey()
		if keep {
			base, token = lcodeKept(filepath.Dir(path))
		}
		rule := map[string]any{"providerId": magpieID, "providerName": "magpie", "enabled": true,
			"config": map[string]any{
				"group":            "standard-personal",
				"access":           map[string]any{"type": "api-key", "apiKey": token},
				"api":              map[string]any{"type": format, "baseUrl": base},
				"personalModelIds": ids, "modelOrder": ids,
			}}
		// turned off in LCode, it stays off
		if e, ok := old["enabled"].(bool); ok {
			rule["enabled"] = e
		}
		// What the user set on it in LCode stays (#2030): its name, logo,
		// visibility, a header or the key's management link
		// (packages/provider/src/config/provider-data-schema.ts). LCode
		// checks the file strictly, so only keys it already took are kept;
		// the address, key, format and model lists are magpie's.
		if old != nil {
			if name, _ := old["providerName"].(string); strings.TrimSpace(name) != "" {
				rule["providerName"] = name
			}
			if oc, _ := old["config"].(map[string]any); oc != nil {
				rule["config"] = mergeKept(oc, rule["config"].(map[string]any), []string{"group", "personalModelIds", "modelOrder"})
			}
			rule = mergeKept(old, rule, nil)
		}
		if at >= 0 {
			providers = slices.Insert(providers, at, any(rule))
		} else {
			providers = append(providers, rule)
		}
	}
	pcr["providerRules"] = lcodeNonNil(providers)
	mcr["providerModelRules"] = lcodeNonNil(models)
	mcr["manualProviderModelRules"] = lcodeNonNil(manual)

	out, err := json.Marshal(doc)
	if err != nil {
		return err
	}
	if string(out) == string(b) {
		return nil
	}
	if b == nil {
		// LCode keeps it private
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(path, nil, 0o600); err != nil {
			return err
		}
	}
	return edit.WriteAtomic(path, out)
}

// LCode offers a model its WebSearch tool only where the model's rule says
// it has native web search (properties.supportsNativeWebSearch, 原生联网搜索
// in a model's settings), off by default. Its tool then asks the model
// again with Anthropic's web_search tool, which only an Anthropic Messages
// provider is sent: on another API format LCode fails the search. magpie's
// gateway runs that tool for any of its models, so it turns native web
// search on for each model it lists while the format is Anthropic Messages
// (Gearclickist on Discord: every magpie model had to be ticked by hand).
//
// LCode writes a change to a model with its recommended config into the
// model's rule, magpie's, and leaves a value equal to LCode's default out of
// it: unticking native web search takes the key out. So the models magpie
// turned it on for are kept in the stash (lcodeSearchedKey), and one of
// them whose rule has no key now was unticked in LCode and stays off. A
// value in the rule is kept as it is.
const lcodeSearchedKey = "lcode.web_search"

// lcodeWebSearch is what magpie's rule for model id, which says old now,
// says of native web search: v, or nothing when set is false. anthropic is
// whether LCode sends the model's provider-native search (the provider's
// format is Anthropic Messages, and the stash could be read). searched holds
// the models magpie turned it on for and is updated.
func lcodeWebSearch(old map[string]any, id string, anthropic bool, searched map[string]bool) (v, set bool) {
	props, _ := old["config"].(map[string]any)
	props, _ = props["properties"].(map[string]any)
	was, had := props["supportsNativeWebSearch"].(bool)
	switch {
	case !anthropic:
		// magpie's on can't be used there; the user's own value stays
		if had && was && searched[id] {
			delete(searched, id)
			return false, false
		}
		return was, had
	case had:
		if was {
			searched[id] = true
		}
		return was, true
	case searched[id]:
		// unticked in LCode
		return false, false
	}
	searched[id] = true
	return true, true
}

// lcodeSearched is the models magpie turned LCode's native web search on
// for, and whether the stash could be read: a stash there that can't be
// read or parsed is unknown, and nothing is turned on.
func lcodeSearched() (map[string]bool, bool) {
	out := map[string]bool{}
	b, err := os.ReadFile(stashPath())
	if errors.Is(err, fs.ErrNotExist) {
		return out, true
	}
	var m map[string]string
	if err != nil || json.Unmarshal(b, &m) != nil {
		return out, false
	}
	if v := m[lcodeSearchedKey]; v != "" {
		for _, id := range strings.Split(v, "\n") {
			out[id] = true
		}
	}
	return out, true
}

// lcodeSearchedPut keeps searched in the stash, only for models magpie
// still lists (ids), and writes it only when that changes it.
func lcodeSearchedPut(searched map[string]bool, ids []string) {
	var keep []string
	for _, id := range ids {
		if searched[id] {
			keep = append(keep, id)
		}
	}
	v := strings.Join(keep, "\n")
	if stashLoad()[lcodeSearchedKey] != v {
		stash(map[string]string{lcodeSearchedKey: v})
	}
}

func lcodeObj(m map[string]any, k string) map[string]any {
	o, ok := m[k].(map[string]any)
	if !ok {
		o = map[string]any{}
		m[k] = o
	}
	return o
}

func lcodeList(m map[string]any, k string) []any { l, _ := m[k].([]any); return l }

func lcodeNonNil(l []any) []any {
	if l == nil {
		return []any{}
	}
	return l
}

// what lcode says after a change (notice.go)
var (
	noticeLcode = newNotice("LCode reads its providers at start-up — restart LCode to see magpie's models in its picker.")
)
