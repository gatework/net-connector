// Package inventoryfile reads a static device inventory from a YAML or CSV
// file, for sites without a Netdisco source.
package inventoryfile

import (
	"bytes"
	"context"
	"encoding/csv"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"path/filepath"
	"slices"
	"strings"

	"github.com/gatework/net-connector/config"
	"github.com/gatework/net-connector/inventory"
)

// ErrFile identifies an inventory file that cannot be used as a whole. No
// partial inventory is ever returned.
var ErrFile = errors.New("inventoryfile: invalid inventory file")

// FileError locates a problem in an inventory file without echoing its
// content. Entry is the one-based device entry (for CSV, the data row); zero
// means the file as a whole.
type FileError struct {
	Entry          int
	Field, Problem string
}

func (e *FileError) Error() string {
	if e.Entry == 0 {
		return "inventoryfile: " + e.Problem
	}
	return fmt.Sprintf("inventoryfile: entry %d: %s %s", e.Entry, e.Field, e.Problem)
}

func (e *FileError) Unwrap() error { return ErrFile }

// fileFields are the accepted columns and keys, in documentation order.
var fileFields = []string{"ip", "name", "dns", "vendor", "os", "model", "os_ver", "serial"}

// Read loads a static device inventory. A ".yml" or ".yaml" file holds a
// root "devices" list of mappings; a ".csv" file holds a header row and one
// device per row. Both use the keys ip, name, dns, vendor, os, model, os_ver
// and serial; only ip is required. Unknown keys, an unusable address and a
// repeated address are errors, so a typo cannot silently drop a device.
//
// The file is read through config.ReadFile: a regular file of at most 16 MiB,
// opened without blocking, with ctx checked while reading.
func Read(ctx context.Context, path string) ([]inventory.Device, error) {
	extension := strings.ToLower(filepath.Ext(path))
	if extension != ".yml" && extension != ".yaml" && extension != ".csv" {
		return nil, &FileError{Problem: "must be a .yml, .yaml or .csv file"}
	}
	data, _, err := config.ReadFile(ctx, path, false)
	if err != nil {
		return nil, errors.Join(ErrFile, err)
	}
	var rows []map[string]string
	if extension == ".csv" {
		rows, err = csvRows(data)
	} else {
		rows, err = yamlRows(data)
	}
	if err != nil {
		return nil, err
	}
	devices := make([]inventory.Device, 0, len(rows))
	seen := map[netip.Addr]bool{}
	for i, row := range rows {
		address, parseErr := netip.ParseAddr(strings.TrimSpace(row["ip"]))
		if parseErr != nil || address.Zone() != "" {
			return nil, &FileError{Entry: i + 1, Field: "ip", Problem: "is not an IP address"}
		}
		if seen[address] {
			return nil, &FileError{Entry: i + 1, Field: "ip", Problem: "repeats an earlier entry"}
		}
		seen[address] = true
		devices = append(devices, inventory.Device{
			IP: address.String(), Name: row["name"], DNS: row["dns"], Vendor: row["vendor"],
			OS: row["os"], Model: row["model"], OSVersion: row["os_ver"], Serial: row["serial"],
		})
	}
	return devices, nil
}

func csvRows(data []byte) ([]map[string]string, error) {
	reader := csv.NewReader(bytes.NewReader(bytes.TrimPrefix(data, []byte("\xef\xbb\xbf"))))
	reader.TrimLeadingSpace = true
	header, err := reader.Read()
	if err != nil {
		return nil, &FileError{Problem: "has no header row"}
	}
	for i, name := range header {
		header[i] = strings.ToLower(strings.TrimSpace(name))
		if !slices.Contains(fileFields, header[i]) {
			return nil, &FileError{Problem: fmt.Sprintf("column %d is not a known field", i+1)}
		}
		if slices.Contains(header[:i], header[i]) {
			return nil, &FileError{Problem: fmt.Sprintf("column %d repeats a field", i+1)}
		}
	}
	if !slices.Contains(header, "ip") {
		return nil, &FileError{Problem: "has no ip column"}
	}
	var rows []map[string]string
	for {
		record, err := reader.Read()
		if errors.Is(err, io.EOF) {
			return rows, nil
		}
		if err != nil {
			// A wrong field count or a malformed quote invalidates the file.
			return nil, &FileError{Entry: len(rows) + 1, Field: "row", Problem: "is malformed"}
		}
		row := make(map[string]string, len(header))
		for i, name := range header {
			row[name] = strings.TrimSpace(record[i])
		}
		rows = append(rows, row)
	}
}

func yamlRows(data []byte) ([]map[string]string, error) {
	document, err := config.ParseYAML(data)
	if err != nil {
		return nil, errors.Join(ErrFile, err)
	}
	for key := range document {
		if key != "devices" {
			return nil, &FileError{Problem: "accepts only a root devices list"}
		}
	}
	list, ok := document["devices"].([]any)
	if !ok {
		return nil, &FileError{Problem: "has no devices list"}
	}
	rows := make([]map[string]string, 0, len(list))
	for i, item := range list {
		entry, ok := item.(map[string]any)
		if !ok {
			return nil, &FileError{Entry: i + 1, Field: "entry", Problem: "is not a mapping"}
		}
		row := make(map[string]string, len(entry))
		for key, value := range entry {
			if !slices.Contains(fileFields, key) {
				return nil, &FileError{Entry: i + 1, Field: "key", Problem: "is not a known field"}
			}
			text, ok := value.(string)
			if !ok && value != nil {
				return nil, &FileError{Entry: i + 1, Field: key, Problem: "must be a string"}
			}
			row[key] = strings.TrimSpace(text)
		}
		rows = append(rows, row)
	}
	return rows, nil
}
