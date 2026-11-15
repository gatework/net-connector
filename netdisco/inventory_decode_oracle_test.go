package netdisco

import (
	"encoding/json"
	"strings"
	"unicode/utf8"

	"github.com/jackc/pgx/v5/pgconn"

	"github.com/gatework/net-connector/inventory"
)

// These oracles preserve the allocation-heavy JSON normalization at 59c1af1.
// Keep them independent of the optimized mapping for boundary comparisons.
func legacyDecodeHTTPInventory(b []byte, maxDevices int, count *int) ([]inventory.Device, error) {
	if len(strings.TrimSpace(string(b))) == 0 {
		return []inventory.Device{}, nil
	}
	if !utf8.Valid(b) {
		return nil, newInventoryError("invalid_json", nil)
	}
	var data []map[string]json.RawMessage
	if e := json.Unmarshal(b, &data); e != nil || data == nil {
		return nil, newInventoryError("invalid_inventory", e)
	}
	*count += len(data)
	if *count > maxDevices {
		return nil, newInventoryError("max_devices", nil)
	}
	rows := make([]inventory.Device, len(data))
	for i, row := range data {
		if row == nil {
			return nil, newInventoryError("invalid_inventory", nil)
		}
		for _, field := range []string{"ip", "name", "dns", "vendor", "os", "model", "os_ver", "serial"} {
			value, ok := row[field]
			if !ok {
				if field == "ip" {
					return nil, newInventoryError("invalid_inventory", nil)
				}
				continue
			}
			var str *string
			if e := json.Unmarshal(value, &str); e != nil || (field == "ip" && (str == nil || strings.TrimSpace(*str) == "")) {
				return nil, newInventoryError("invalid_inventory", nil)
			}
		}
		normalized := make(map[string]json.RawMessage)
		for _, f := range []string{"ip", "name", "dns", "vendor", "os", "model", "os_ver", "serial"} {
			if v, ok := row[f]; ok {
				normalized[f] = v
			}
		}
		body, _ := json.Marshal(normalized)
		if e := json.Unmarshal(body, &rows[i]); e != nil {
			return nil, newInventoryError("invalid_inventory", nil)
		}
	}
	return rows, nil
}

func legacyDecodePostgresRow(fields []pgconn.FieldDescription, values [][]byte, limits Limits, response, total *int64) (inventory.Device, error) {
	selected := make(map[string]*string)
	for i, v := range values {
		*response += int64(len(fields[i].Name) + len(v))
		*total += int64(len(fields[i].Name) + len(v))
		if *response > limits.MaxResponseBytes {
			return inventory.Device{}, newInventoryError("max_response_bytes", nil)
		}
		if *total > limits.MaxInventoryBytes {
			return inventory.Device{}, newInventoryError("max_inventory_bytes", nil)
		}
		switch fields[i].Name {
		case "ip", "name", "dns", "vendor", "os", "model", "os_ver", "serial":
			if v == nil {
				selected[fields[i].Name] = nil
			} else {
				text := string(v)
				selected[fields[i].Name] = &text
			}
		}
	}
	if selected["ip"] == nil || strings.TrimSpace(*selected["ip"]) == "" {
		return inventory.Device{}, newInventoryError("invalid_inventory", nil)
	}
	body, _ := json.Marshal(selected)
	var device inventory.Device
	if err := json.Unmarshal(body, &device); err != nil {
		return inventory.Device{}, newInventoryError("invalid_inventory", err)
	}
	return device, nil
}
