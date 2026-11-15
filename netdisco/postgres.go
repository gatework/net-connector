package netdisco

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/gatework/net-connector/inventory"
)

// PostgresOptions defines a read-only inventory query and its resource limits.
type PostgresOptions struct {
	Connection, Query string
	Parameters        []any
	Limits            Limits
}

// Postgres fetches inventory through a bounded read-only PostgreSQL cursor.
type Postgres struct {
	connection *pgx.ConnConfig
	query      string
	parameters []any
	limits     Limits
}

const postgresProtocolOverhead int64 = 1 << 20

// NewPostgres validates and owns query parameters and connection settings.
func NewPostgres(o PostgresOptions) (*Postgres, error) {
	if strings.TrimSpace(o.Query) == "" || strings.ContainsRune(o.Query, 0) {
		return nil, newInventoryError("invalid_query", nil)
	}
	parameters := slices.Clone(o.Parameters)
	for _, p := range parameters {
		switch v := p.(type) {
		case nil, bool, int, int64, int32:
		case float64:
			if math.IsNaN(v) || math.IsInf(v, 0) {
				return nil, newInventoryError("invalid_query_params", nil)
			}
		case string:
			if strings.ContainsRune(v, 0) {
				return nil, newInventoryError("invalid_query_params", nil)
			}
		default:
			return nil, newInventoryError("invalid_query_params", nil)
		}
	}
	cfg, e := pgx.ParseConfig(o.Connection)
	if e != nil {
		return nil, newInventoryError("invalid_connection", nil)
	}
	limits, e := o.Limits.normalize()
	if e != nil {
		return nil, e
	}
	cfg.MaxProtocolMessageBodyLen = postgresProtocolBodyLimit(limits)
	return &Postgres{cfg, o.Query, parameters, limits}, nil
}

// postgresProtocolBodyLimit bounds pgx's per-message allocation before rows are
// decoded. The allowance covers row framing and column metadata beyond the
// application payload budget.
func postgresProtocolBodyLimit(limits Limits) int {
	budget := min(limits.MaxResponseBytes, limits.MaxInventoryBytes)
	maxInt := int64(^uint(0) >> 1)
	if budget > maxInt-postgresProtocolOverhead {
		return int(maxInt)
	}
	return int(budget + postgresProtocolOverhead)
}

func (p *Postgres) String() string { return "netdisco.Postgres" }

// GoString formats safe source metadata without credentials.
func (p *Postgres) GoString() string { return p.String() }

// Devices fetches rows in a read-only transaction and closes its owned connection.
func (p *Postgres) Devices(parent context.Context) (result []inventory.Device, err error) {
	ctx, cancel := context.WithTimeout(parent, p.limits.Timeout)
	defer cancel()
	conn, e := pgx.ConnectConfig(ctx, p.connection.Copy())
	if e != nil {
		return nil, newInventoryError("connection_failed", e)
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.WithoutCancel(parent), 2*time.Second)
		defer cancel()
		if e := conn.Close(cleanup); err == nil && e != nil {
			result = nil
			err = newInventoryError("connection_failed", e)
		}
	}()
	tx, e := conn.BeginTx(ctx, pgx.TxOptions{AccessMode: pgx.ReadOnly})
	if e != nil {
		return nil, newInventoryError("query_failed", e)
	}
	// Extended protocol rejects multi-statements even when there are no parameters.
	args := append([]any{pgx.QueryExecModeExec}, p.parameters...)
	declaration, e := tx.Query(ctx, "DECLARE net_connector_inventory NO SCROLL CURSOR FOR\n"+p.query, args...)
	if e != nil {
		return nil, newInventoryError("query_failed", e)
	}
	declaration.Close()
	if e = declaration.Err(); e != nil {
		return nil, newInventoryError("query_failed", e)
	}
	output := make([]inventory.Device, 0)
	var total int64
	for range p.limits.MaxPages {
		rows, e := tx.Query(ctx, fmt.Sprintf("FETCH FORWARD %d FROM net_connector_inventory", p.limits.PageSize), pgx.QueryExecModeExec)
		if e != nil {
			return nil, newInventoryError("query_failed", e)
		}
		count, e := p.readPage(ctx, rows, &output, &total)
		if e != nil {
			return nil, e
		}
		if count < p.limits.PageSize {
			if e = tx.Commit(ctx); e != nil {
				return nil, newInventoryError("query_failed", e)
			}
			if e := ctx.Err(); e != nil {
				return nil, newInventoryError("query_failed", e)
			}
			return output, nil
		}
	}
	return nil, newInventoryError("max_pages", nil)
}

func (p *Postgres) readPage(ctx context.Context, rows pgx.Rows, output *[]inventory.Device, total *int64) (int, error) {
	columns, e := postgresColumns(ctx, rows.FieldDescriptions())
	if e != nil {
		rows.Close()
		return 0, e
	}

	count := 0
	var response int64
	for rows.Next() {
		if e := ctx.Err(); e != nil {
			rows.Close()
			return 0, newInventoryError("query_failed", e)
		}
		count++
		if len(*output) >= p.limits.MaxDevices {
			rows.Close()
			return 0, newInventoryError("max_devices", nil)
		}
		device, e := decodePostgresRow(ctx, columns, rows.RawValues(), p.limits, &response, total)
		if e != nil {
			rows.Close()
			return 0, e
		}

		*output = append(*output, device)
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return 0, newInventoryError("query_failed", e)
	}
	return count, nil
}

// Column selection is fixed for one fetched page; raw buffers belong to pgx.
type postgresColumn struct {
	name  string
	field int
}

func postgresColumns(ctx context.Context, fields []pgconn.FieldDescription) ([]postgresColumn, error) {
	columns := make([]postgresColumn, len(fields))
	seen := make(map[string]bool, len(fields))
	valid := false
	for i, f := range fields {
		if e := ctx.Err(); e != nil {
			return nil, newInventoryError("query_failed", e)
		}
		if seen[f.Name] {
			return nil, newInventoryError("invalid_inventory", nil)
		}
		seen[f.Name] = true
		columns[i] = postgresColumn{name: f.Name, field: -1}
		for j, name := range inventoryFieldNames {
			if f.Name == name {
				columns[i].field = j
				break
			}
		}
		if f.Name == "ip" {
			valid = true
		}
	}
	if !valid {
		return nil, newInventoryError("invalid_inventory", nil)
	}
	return columns, nil
}

func decodePostgresRow(ctx context.Context, columns []postgresColumn, values [][]byte, limits Limits, response, total *int64) (inventory.Device, error) {
	var device inventory.Device
	fields := inventoryFields(&device)
	for i, v := range values {
		if e := ctx.Err(); e != nil {
			return inventory.Device{}, newInventoryError("query_failed", e)
		}
		column := columns[i]
		// Budget every column, including ignored fields and null values' names.
		*response += int64(len(column.name) + len(v))
		*total += int64(len(column.name) + len(v))
		if *response > limits.MaxResponseBytes {
			return inventory.Device{}, newInventoryError("max_response_bytes", nil)
		}
		if *total > limits.MaxInventoryBytes {
			return inventory.Device{}, newInventoryError("max_inventory_bytes", nil)
		}
		if column.field >= 0 {
			text := string(v) // Own the bytes before rows.Next reuses the driver's buffer.
			if !utf8.ValidString(text) {
				// encoding/json replaces each malformed byte, including adjacent malformed bytes.
				text = string([]rune(text))
			}
			*fields[column.field] = text
		}
	}
	if strings.TrimSpace(device.IP) == "" {
		return inventory.Device{}, newInventoryError("invalid_inventory", nil)
	}
	if e := ctx.Err(); e != nil {
		return inventory.Device{}, newInventoryError("query_failed", e)
	}
	return device, nil
}

// MarshalJSON exposes operational metadata only; credentials remain available explicitly on the options.
func (o PostgresOptions) MarshalJSON() ([]byte, error) {
	metadata := struct {
		Host, User, Database string
		Port                 uint16
		ParameterCount       int
		Limits               Limits
	}{ParameterCount: len(o.Parameters), Limits: o.Limits}
	if o.Connection != "" {
		if cfg, err := pgx.ParseConfig(o.Connection); err == nil {
			metadata.Host, metadata.User, metadata.Database, metadata.Port = cfg.Host, cfg.User, cfg.Database, cfg.Port
		}
	}
	return json.Marshal(metadata)
}
func (o PostgresOptions) String() string {
	b, _ := o.MarshalJSON()
	return "PostgresOptions" + string(b)
}

// GoString formats safe source metadata without credentials.
func (o PostgresOptions) GoString() string { return o.String() }
