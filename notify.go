// notify.go: dependency-free self notifier, Go stdlib only.
// Run: NOTIFY_TOKEN=<secret> go run notify.go
//
//	Then: curl -X POST localhost:47124/alert -H 'X-Token: <secret>' \
//	  -d '{"title":"VPS disk alert","message":"Disk at 92%","topic":"self"}'
//
// Read: /alerts?token=<secret> or /feed?token=<secret>&topic=self
// No push: a phone polls /feed in an RSS reader, or a second box
// polls /healthz and alerts when this one stops answering.
//
// Friends: NOTIFY_TOKEN is the admin token and can read and write
// every topic. Each line of tokens.txt (the default tokens file)
// gives one friend a token and the topics it may read and write:
//
//	friendtoken1 alice # Alice
//	friendtoken2 bob site-watch # Bob
//
// Add one with: go run notify.go add_token [topic]
// The topic defaults to main, which all such friends share;
// pass a distinct topic per friend, or edit the file, for
// isolation. Tokens are provisioned by hand only, there is no
// endpoint that creates them, so nobody can mint tokens to
// flood the server.
// # starts a comment, full-line or trailing, so a line can carry
// the friend's name: friendtoken1 alice # Alice
// A friend token with no topic filter sees only its own topics.
// The tokens file is re-read on every request, so adding a friend
// needs no restart. Keep the file chmod 600.
//
// Reverse proxy: see caddy.sh (setup, add, remove, list, purge).
//
// Docker: this repo also ships a Dockerfile and manage.sh. The
// container runs only this file, as user 10001, read-only, with
// no capabilities, and the host's Caddy proxies /notify to it on
// localhost:47124. Data (alerts.jsonl, tokens.txt) lives in the
// bind-mounted data dir, default /var/lib/notify.
package main

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/json"
	"encoding/xml"
	"flag"
	"fmt"
	"html"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

type Alert struct {
	Time    time.Time `json:"time"`
	Title   string    `json:"title"`
	Message string    `json:"message"`
	Topic   string    `json:"topic"`
}

var (
	addr   = flag.String("addr", ":47124", "listen address")
	data   = flag.String("data", "alerts.jsonl", "alert log file")
	tokens = flag.String("tokens", "tokens.txt", "friend tokens file: one line per friend, <token> <topic> [topic...]")
	token  = os.Getenv("NOTIFY_TOKEN")
	mu     sync.Mutex
	list   []Alert
)

// auth resolves the request token to its allowed topics. The admin
// token (NOTIFY_TOKEN) gets nil, meaning every topic. A friend token
// from the tokens file gets only its listed topics. Unknown tokens
// fail, and the tokens file is re-read on every request.
func auth(r *http.Request) ([]string, bool) {
	t := r.Header.Get("X-Token")
	if t == "" {
		t = r.URL.Query().Get("token")
	}
	if token != "" && subtle.ConstantTimeCompare([]byte(t), []byte(token)) == 1 {
		return nil, true
	}
	if *tokens == "" {
		return nil, false
	}
	b, err := os.ReadFile(*tokens)
	if err != nil {
		return nil, false
	}
	for _, line := range strings.Split(string(b), "\n") {
		if i := strings.Index(line, "#"); i >= 0 {
			line = line[:i]
		}
		f := strings.Fields(line)
		if len(f) < 2 {
			continue
		}
		if subtle.ConstantTimeCompare([]byte(t), []byte(f[0])) == 1 {
			return f[1:], true
		}
	}
	return nil, false
}

func allowed(topics []string, topic string) bool {
	if topics == nil {
		return true
	}
	for _, t := range topics {
		if t == topic {
			return true
		}
	}
	return false
}

func load() {
	b, err := os.ReadFile(*data)
	if err != nil {
		return
	}
	for _, line := range strings.Split(string(b), "\n") {
		if line == "" {
			continue
		}
		var a Alert
		if json.Unmarshal([]byte(line), &a) == nil {
			list = append(list, a)
		}
	}
}

func postAlert(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	topics, ok := auth(r)
	if !ok {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	var a Alert
	if err := json.NewDecoder(r.Body).Decode(&a); err != nil || a.Title == "" {
		http.Error(w, "need title", http.StatusBadRequest)
		return
	}
	if a.Topic == "" {
		if topics == nil {
			a.Topic = "self"
		} else {
			a.Topic = topics[0]
		}
	}
	if !allowed(topics, a.Topic) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	a.Time = time.Now().UTC()
	b, _ := json.Marshal(a)
	mu.Lock()
	list = append(list, a)
	f, err := os.OpenFile(*data, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0600)
	if err == nil {
		f.Write(append(b, '\n'))
		f.Close()
	}
	mu.Unlock()
	w.WriteHeader(http.StatusCreated)
}

func alertsPage(w http.ResponseWriter, r *http.Request) {
	topics, ok := auth(r)
	if !ok {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	topic := r.URL.Query().Get("topic")
	if topic != "" && !allowed(topics, topic) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	mu.Lock()
	defer mu.Unlock()
	fmt.Fprintln(w, "<pre>")
	for i := len(list) - 1; i >= 0; i-- {
		a := list[i]
		if topic != "" && a.Topic != topic {
			continue
		}
		if !allowed(topics, a.Topic) {
			continue
		}
		fmt.Fprintf(w, "%s [%s] %s: %s\n", a.Time.Format(time.RFC3339), a.Topic, html.EscapeString(a.Title), html.EscapeString(a.Message))
	}
	fmt.Fprintln(w, "</pre>")
}

type rss struct {
	XMLName xml.Name `xml:"rss"`
	Version string   `xml:"version,attr"`
	Channel chan_    `xml:"channel"`
}
type chan_ struct {
	Title string    `xml:"title"`
	Items []rssItem `xml:"item"`
}
type rssItem struct {
	Title   string `xml:"title"`
	Desc    string `xml:"description"`
	PubDate string `xml:"pubDate"`
}

func feed(w http.ResponseWriter, r *http.Request) {
	topics, ok := auth(r)
	if !ok {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	topic := r.URL.Query().Get("topic")
	if topic != "" && !allowed(topics, topic) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	mu.Lock()
	defer mu.Unlock()
	out := rss{Version: "2.0", Channel: chan_{Title: "notify"}}
	for i := len(list) - 1; i >= 0; i-- {
		a := list[i]
		if topic != "" && a.Topic != topic {
			continue
		}
		if !allowed(topics, a.Topic) {
			continue
		}
		out.Channel.Items = append(out.Channel.Items, rssItem{a.Title, a.Message, a.Time.Format(time.RFC1123Z)})
	}
	w.Header().Set("Content-Type", "application/rss+xml")
	xml.NewEncoder(w).Encode(out)
}

// addToken generates a random token, appends it with its topic to
// the tokens file, and prints it. The topic defaults to main.
func addToken(topic string) {
	if topic == "" {
		topic = "main"
	}
	b, err := os.ReadFile(*tokens)
	if err != nil && !os.IsNotExist(err) {
		log.Fatal(err)
	}
	have := map[string]bool{}
	for _, line := range strings.Split(string(b), "\n") {
		if f := strings.Fields(line); len(f) > 0 {
			have[f[0]] = true
		}
	}
	var tok string
	for {
		r := make([]byte, 16)
		if _, err := rand.Read(r); err != nil {
			log.Fatal(err)
		}
		tok = fmt.Sprintf("%x", r)
		if !have[tok] {
			break
		}
	}
	f, err := os.OpenFile(*tokens, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0600)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Fprintf(f, "%s %s\n", tok, topic)
	f.Close()
	fmt.Printf("added: %s %s -> %s\n", tok, topic, *tokens)
}

func main() {
	flag.Parse()
	if flag.Arg(0) == "add_token" {
		addToken(flag.Arg(1))
		return
	}
	if token == "" {
		log.Fatal("NOTIFY_TOKEN is required")
	}
	load()
	http.HandleFunc("/alert", postAlert)
	http.HandleFunc("/alerts", alertsPage)
	http.HandleFunc("/feed", feed)
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) { fmt.Fprintln(w, "ok") })
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "notify: POST /alert, GET /alerts, GET /feed, GET /healthz")
	})
	log.Fatal(http.ListenAndServe(*addr, nil))
}
