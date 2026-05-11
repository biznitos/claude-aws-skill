# Go quickstart

Uses `net/http` from stdlib, AWS SDK v2, and `database/sql` with `pgx` for Postgres. No web framework dependency. Easy to adapt to chi, gin, echo, fiber.

## Dependencies

```bash
go get github.com/aws/aws-sdk-go-v2/aws \
       github.com/aws/aws-sdk-go-v2/config \
       github.com/aws/aws-sdk-go-v2/credentials \
       github.com/aws/aws-sdk-go-v2/service/sesv2 \
       github.com/jackc/pgx/v5/pgxpool
```

## Env vars

Replace `YEHRO` with your `<UPPER_SLUG>`.

```
YEHRO_SES_REGION=us-east-1
YEHRO_SES_ACCESS_KEY=AKIA...
YEHRO_SES_SECRET_KEY=...
YEHRO_SES_CONFIGURATION_SET=yehro
YEHRO_SES_FROM_EMAIL=noreply@yehro.com
YEHRO_SES_REPLY_TO=support@yehro.com
YEHRO_SES_SNS_TOPIC_ARN=arn:aws:sns:us-east-1:123:yehro-ses-events
YEHRO_SES_WEBHOOK_SECRET=<64 hex chars>
```

## Migration (raw SQL or use whatever migration tool the project uses)

```sql
CREATE TABLE ses_suppressions (
    id            BIGSERIAL PRIMARY KEY,
    email         TEXT NOT NULL UNIQUE,
    reason        TEXT NOT NULL,
    reason_detail TEXT,
    last_event_at TIMESTAMPTZ NOT NULL,
    event_count   INTEGER NOT NULL DEFAULT 1,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX ix_ses_suppressions_reason ON ses_suppressions (reason);
CREATE INDEX ix_ses_suppressions_last_event_at ON ses_suppressions (last_event_at);
```

## Suppression — `internal/suppressions/suppressions.go`

```go
package suppressions

import (
	"context"
	"encoding/json"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

var PermanentReasons = []string{"bounce_permanent", "complaint", "manual"}

type Store struct {
	db *pgxpool.Pool
}

func New(db *pgxpool.Pool) *Store { return &Store{db: db} }

func (s *Store) Suppressed(ctx context.Context, email string) (bool, error) {
	e := strings.ToLower(email)
	var n int
	err := s.db.QueryRow(ctx,
		`SELECT 1 FROM ses_suppressions
		 WHERE email = $1 AND reason = ANY($2) LIMIT 1`,
		e, PermanentReasons,
	).Scan(&n)
	if err != nil {
		if err.Error() == "no rows in result set" {
			return false, nil
		}
		return false, err
	}
	return true, nil
}

func (s *Store) Record(ctx context.Context, email, reason string, detail map[string]any) error {
	e := strings.ToLower(email)
	detailJSON, _ := json.Marshal(detail)
	now := time.Now().UTC()
	_, err := s.db.Exec(ctx, `
		INSERT INTO ses_suppressions
		    (email, reason, reason_detail, last_event_at, event_count, created_at, updated_at)
		VALUES ($1, $2, $3, $4, 1, $5, $5)
		ON CONFLICT (email) DO UPDATE SET
		    reason = EXCLUDED.reason,
		    reason_detail = EXCLUDED.reason_detail,
		    last_event_at = EXCLUDED.last_event_at,
		    updated_at = EXCLUDED.updated_at,
		    event_count = ses_suppressions.event_count + 1
	`, e, reason, string(detailJSON), now, now)
	return err
}

func (s *Store) Unsuppress(ctx context.Context, email string) error {
	_, err := s.db.Exec(ctx, `DELETE FROM ses_suppressions WHERE email = $1`, strings.ToLower(email))
	return err
}
```

## Mailer — `internal/mailer/mailer.go`

```go
package mailer

import (
	"context"
	"fmt"
	"os"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/sesv2"
	"github.com/aws/aws-sdk-go-v2/service/sesv2/types"

	"yourapp/internal/suppressions"   // <-- replace import path
)

const prefix = "YEHRO_"   // <-- change to your <UPPER_SLUG>_

type Mailer struct {
	client      *sesv2.Client
	from        string
	replyTo     string
	configSet   string
	suppression *suppressions.Store
}

type Message struct {
	To       []string
	Cc       []string
	Bcc      []string
	Subject  string
	Text     string
	HTML     string
	ReplyTo  string
}

type SendResult struct {
	MessageID string
	Dropped   []string  // non-empty => skipped due to suppression
	Err       error
}

func env(k string) string {
	v := os.Getenv(k)
	if v == "" {
		panic(fmt.Sprintf("missing env var: %s", k))
	}
	return v
}

func New(ctx context.Context, sup *suppressions.Store) (*Mailer, error) {
	region := env(prefix + "SES_REGION")
	cfg, err := config.LoadDefaultConfig(ctx,
		config.WithRegion(region),
		config.WithCredentialsProvider(credentials.NewStaticCredentialsProvider(
			env(prefix+"SES_ACCESS_KEY"),
			env(prefix+"SES_SECRET_KEY"),
			"",
		)),
	)
	if err != nil {
		return nil, err
	}
	return &Mailer{
		client:      sesv2.NewFromConfig(cfg),
		from:        env(prefix + "SES_FROM_EMAIL"),
		replyTo:     env(prefix + "SES_REPLY_TO"),
		configSet:   env(prefix + "SES_CONFIGURATION_SET"),
		suppression: sup,
	}, nil
}

// Deliver — raw send, no suppression check.
func (m *Mailer) Deliver(ctx context.Context, msg Message) (string, error) {
	replyTo := msg.ReplyTo
	if replyTo == "" {
		replyTo = m.replyTo
	}
	body := &types.Body{Text: &types.Content{Data: aws.String(msg.Text), Charset: aws.String("UTF-8")}}
	if msg.HTML != "" {
		body.Html = &types.Content{Data: aws.String(msg.HTML), Charset: aws.String("UTF-8")}
	}

	out, err := m.client.SendEmail(ctx, &sesv2.SendEmailInput{
		FromEmailAddress: aws.String(m.from),
		ReplyToAddresses: []string{replyTo},
		Destination: &types.Destination{
			ToAddresses:  msg.To,
			CcAddresses:  msg.Cc,
			BccAddresses: msg.Bcc,
		},
		Content: &types.EmailContent{
			Simple: &types.Message{
				Subject: &types.Content{Data: aws.String(msg.Subject), Charset: aws.String("UTF-8")},
				Body:    body,
			},
		},
		ConfigurationSetName: aws.String(m.configSet),
	})
	if err != nil {
		return "", err
	}
	return aws.ToString(out.MessageId), nil
}

// DeliverChecked — checks suppression list first.
func (m *Mailer) DeliverChecked(ctx context.Context, msg Message) SendResult {
	all := append(append(append([]string{}, msg.To...), msg.Cc...), msg.Bcc...)
	var blocked []string
	for _, a := range all {
		ok, err := m.suppression.Suppressed(ctx, a)
		if err != nil {
			return SendResult{Err: err}
		}
		if ok {
			blocked = append(blocked, a)
		}
	}
	if len(blocked) > 0 {
		return SendResult{Dropped: blocked}
	}
	id, err := m.Deliver(ctx, msg)
	if err != nil {
		return SendResult{Err: err}
	}
	return SendResult{MessageID: id}
}
```

## Event processor — `internal/ses/events.go`

```go
package ses

import (
	"context"
	"encoding/json"
	"log/slog"

	"yourapp/internal/suppressions"
)

type Mail struct {
	MessageID   string   `json:"messageId"`
	Source      string   `json:"source"`
	Destination []string `json:"destination"`
}

type BouncedRecipient struct {
	EmailAddress   string `json:"emailAddress"`
	Action         string `json:"action"`
	Status         string `json:"status"`
	DiagnosticCode string `json:"diagnosticCode"`
}

type Bounce struct {
	BounceType        string             `json:"bounceType"`
	BounceSubType     string             `json:"bounceSubType"`
	BouncedRecipients []BouncedRecipient `json:"bouncedRecipients"`
	FeedbackID        string             `json:"feedbackId"`
}

type Complaint struct {
	ComplainedRecipients   []struct{ EmailAddress string `json:"emailAddress"` } `json:"complainedRecipients"`
	ComplaintFeedbackType  string `json:"complaintFeedbackType"`
	FeedbackID             string `json:"feedbackId"`
}

type Event struct {
	EventType string          `json:"eventType"`
	Mail      Mail            `json:"mail"`
	Bounce    *Bounce         `json:"bounce,omitempty"`
	Complaint *Complaint      `json:"complaint,omitempty"`
	Delivery  json.RawMessage `json:"delivery,omitempty"`
	Reject    json.RawMessage `json:"reject,omitempty"`
}

type Processor struct{ sup *suppressions.Store }

func NewProcessor(sup *suppressions.Store) *Processor { return &Processor{sup: sup} }

func (p *Processor) Process(ctx context.Context, ev Event) error {
	switch ev.EventType {
	case "Bounce":
		return p.handleBounce(ctx, ev)
	case "Complaint":
		return p.handleComplaint(ctx, ev)
	case "Delivery":
		slog.Info("ses delivered", "messageId", ev.Mail.MessageID)
	case "Send":
		slog.Debug("ses send", "messageId", ev.Mail.MessageID)
	case "Reject":
		slog.Error("ses reject", "messageId", ev.Mail.MessageID, "reject", string(ev.Reject))
	default:
		slog.Info("ses unhandled event", "type", ev.EventType)
	}
	return nil
}

func (p *Processor) handleBounce(ctx context.Context, ev Event) error {
	if ev.Bounce == nil {
		return nil
	}
	reason := "bounce_transient"
	if ev.Bounce.BounceType == "Permanent" {
		reason = "bounce_permanent"
	}
	for _, r := range ev.Bounce.BouncedRecipients {
		detail := map[string]any{
			"type":        ev.Bounce.BounceType,
			"subtype":     ev.Bounce.BounceSubType,
			"action":      r.Action,
			"status":      r.Status,
			"diagnostic":  r.DiagnosticCode,
			"message_id":  ev.Mail.MessageID,
			"feedback_id": ev.Bounce.FeedbackID,
		}
		if err := p.sup.Record(ctx, r.EmailAddress, reason, detail); err != nil {
			return err
		}
		slog.Info("ses bounce", "type", ev.Bounce.BounceType, "email", r.EmailAddress)
	}
	return nil
}

func (p *Processor) handleComplaint(ctx context.Context, ev Event) error {
	if ev.Complaint == nil {
		return nil
	}
	for _, r := range ev.Complaint.ComplainedRecipients {
		detail := map[string]any{
			"feedback_type": ev.Complaint.ComplaintFeedbackType,
			"message_id":    ev.Mail.MessageID,
			"feedback_id":   ev.Complaint.FeedbackID,
		}
		if err := p.sup.Record(ctx, r.EmailAddress, "complaint", detail); err != nil {
			return err
		}
		slog.Warn("ses complaint", "email", r.EmailAddress)
	}
	return nil
}
```

## Webhook handler — `internal/sesweb/handler.go`

```go
package sesweb

import (
	"crypto/subtle"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"

	"yourapp/internal/ses"
)

const prefix = "YEHRO_"  // <-- change

var (
	webhookSecret     = os.Getenv(prefix + "SES_WEBHOOK_SECRET")
	expectedTopicARN  = os.Getenv(prefix + "SES_SNS_TOPIC_ARN")
	snsHostRE         = regexp.MustCompile(`^sns\.[a-z0-9-]+\.amazonaws\.com$`)
)

type SnsPayload struct {
	Type         string `json:"Type"`
	MessageID    string `json:"MessageId"`
	TopicArn     string `json:"TopicArn"`
	Message      string `json:"Message"`
	SubscribeURL string `json:"SubscribeURL"`
}

type Handler struct{ proc *ses.Processor }

func NewHandler(proc *ses.Processor) *Handler { return &Handler{proc: proc} }

// Mount with: mux.HandleFunc("POST /webhooks/ses/{token}", h.Receive)
func (h *Handler) Receive(w http.ResponseWriter, r *http.Request) {
	// 1. URL secret — constant time
	token := r.PathValue("token")
	if subtle.ConstantTimeCompare([]byte(token), []byte(webhookSecret)) != 1 {
		http.NotFound(w, r)
		return
	}

	body, err := io.ReadAll(io.LimitReader(r.Body, 256*1024))
	if err != nil {
		http.Error(w, "read failed", http.StatusBadRequest)
		return
	}

	var p SnsPayload
	if err := json.Unmarshal(body, &p); err != nil {
		http.Error(w, "bad JSON", http.StatusBadRequest)
		return
	}

	if p.TopicArn != expectedTopicARN {
		slog.Warn("ses_webhook topic arn mismatch", "got", p.TopicArn)
		http.Error(w, "bad topic", http.StatusBadRequest)
		return
	}

	ctx := r.Context()
	switch p.Type {
	case "SubscriptionConfirmation":
		h.confirmSubscription(p)
		w.WriteHeader(http.StatusOK)
	case "Notification":
		var ev ses.Event
		if err := json.Unmarshal([]byte(p.Message), &ev); err != nil {
			slog.Error("ses_webhook bad event JSON", "err", err)
			w.WriteHeader(http.StatusOK)  // can't recover from bad JSON; ack so SNS doesn't retry forever
			return
		}
		if err := h.proc.Process(ctx, ev); err != nil {
			slog.Error("ses_webhook processing failed", "err", err)
			http.Error(w, "process failed", http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusOK)
	case "UnsubscribeConfirmation":
		slog.Warn("ses_webhook unsubscribe confirmation", "topic", p.TopicArn)
		w.WriteHeader(http.StatusOK)
	default:
		slog.Info("ses_webhook unknown type", "type", p.Type)
		w.WriteHeader(http.StatusOK)
	}
}

func (h *Handler) confirmSubscription(p SnsPayload) {
	u, err := url.Parse(p.SubscribeURL)
	if err != nil || u.Scheme != "https" || !snsHostRE.MatchString(strings.ToLower(u.Host)) {
		slog.Error("ses_webhook refusing SubscribeURL with bad host", "host", u.Host)
		return
	}
	resp, err := http.Get(p.SubscribeURL)
	if err != nil {
		slog.Error("ses_webhook confirmation GET failed", "err", err)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 == 2 {
		slog.Info("ses_webhook subscription confirmed", "topic", p.TopicArn)
	} else {
		slog.Error("ses_webhook confirmation got status", "code", resp.StatusCode)
	}
}
```

Mount in `main.go`:

```go
mux := http.NewServeMux()
handler := sesweb.NewHandler(processor)
mux.HandleFunc("POST /webhooks/ses/{token}", handler.Receive)
```

`POST /path/{token}` path-param routing requires Go 1.22+. For older Go, use chi or strip the prefix manually.

## Test

```go
ctx := context.Background()
m, _ := mailer.New(ctx, sup)

// 1. success
m.DeliverChecked(ctx, mailer.Message{To: []string{"success@simulator.amazonses.com"}, Subject: "t", Text: "t"})

// 2. bounce
m.DeliverChecked(ctx, mailer.Message{To: []string{"bounce@simulator.amazonses.com"}, Subject: "t", Text: "t"})
time.Sleep(30 * time.Second)
// query ses_suppressions; row appears with reason=bounce_permanent

// 3. suppressed
res := m.DeliverChecked(ctx, mailer.Message{To: []string{"bounce@simulator.amazonses.com"}, Subject: "t", Text: "t"})
// res.Dropped == ["bounce@simulator.amazonses.com"]
```
