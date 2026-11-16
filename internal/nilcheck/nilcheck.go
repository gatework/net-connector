// Package nilcheck detects nil values hidden behind a non-nil interface.
package nilcheck

import "reflect"

// IsNil reports whether v is nil or an interface holding a nil pointer, map,
// slice, channel or function. A plain nil comparison misses the second case.
func IsNil(v any) bool {
	if v == nil {
		return true
	}
	r := reflect.ValueOf(v)
	switch r.Kind() { //nolint:exhaustive // Only nil-capable reflection kinds support IsNil; all other kinds are non-nil.
	case reflect.Chan, reflect.Func, reflect.Interface, reflect.Map, reflect.Pointer, reflect.Slice:
		return r.IsNil()
	default:
		return false
	}
}
