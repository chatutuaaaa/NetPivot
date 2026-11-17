package control

import (
	"context"
	"database/sql"
	"encoding/json"
	"sync"

	_ "github.com/jackc/pgx/v5/stdlib"
)

// Store serializes mutations so invitation use and address allocation are atomic.
type Store interface {
	Run(context.Context, func(*State) error) error
}

type postgres struct{ db *sql.DB }

func OpenPostgres(ctx context.Context, dsn string) (Store, error) {
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		return nil, err
	}
	if _, err = db.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS netpivot_state (
		id integer PRIMARY KEY CHECK (id = 1), body jsonb NOT NULL
	)`); err == nil {
		_, err = db.ExecContext(ctx, `INSERT INTO netpivot_state VALUES (1, '{}') ON CONFLICT DO NOTHING`)
	}
	if err != nil {
		db.Close()
		return nil, err
	}
	return postgres{db}, nil
}

func (p postgres) Run(ctx context.Context, fn func(*State) error) error {
	tx, err := p.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var data []byte
	if err := tx.QueryRowContext(ctx, `SELECT body FROM netpivot_state WHERE id=1 FOR UPDATE`).Scan(&data); err != nil {
		return err
	}
	updated, err := mutate(data, fn)
	if err != nil {
		return err
	}
	// Avoid rewriting the row when polling endpoints only read it.
	var original State
	if err := json.Unmarshal(data, &original); err != nil {
		return err
	}
	canonical, err := json.Marshal(original)
	if err != nil {
		return err
	}
	if string(updated) != string(canonical) {
		if _, err := tx.ExecContext(ctx, `UPDATE netpivot_state SET body=$1 WHERE id=1`, updated); err != nil {
			return err
		}
	}
	return tx.Commit()
}

type MemoryStore struct {
	mu   sync.Mutex
	data []byte
}

func (m *MemoryStore) Run(_ context.Context, fn func(*State) error) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	input := m.data
	if len(input) == 0 {
		input = []byte("{}")
	}
	data, err := mutate(input, fn)
	if err == nil {
		m.data = data
	}
	return err
}

func mutate(input []byte, fn func(*State) error) ([]byte, error) {
	state := State{
		Devices: map[string]Device{}, Challenges: map[string]Challenge{},
		Tokens: map[string]Token{}, Networks: map[string]*Network{},
		Created: map[string]string{}, Quarantine: map[int]timeStamp{},
	}
	if err := json.Unmarshal(input, &state); err != nil {
		return nil, err
	}
	if err := fn(&state); err != nil {
		return nil, err
	}
	return json.Marshal(state)
}
