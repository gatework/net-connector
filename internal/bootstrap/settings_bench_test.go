package bootstrap

import (
	"context"
	"testing"

	"github.com/gatework/net-connector/config"
)

var tftpPolicyBenchmarkSink any

func benchmarkServices(b *testing.B) *Services {
	b.Helper()
	policy, err := config.Load(context.Background(), config.Options{
		Name:        "backup",
		CWD:         b.TempDir(),
		Home:        b.TempDir(),
		Directories: []string{},
		Defaults:    config.Defaults("tftp"),
	})
	if err != nil {
		b.Fatal(err)
	}
	services, err := New(policy, nil)
	if err != nil {
		b.Fatal(err)
	}
	return services
}

func BenchmarkTFTPPolicy(b *testing.B) {
	services := benchmarkServices(b)
	for _, tc := range []struct {
		name string
		call func() (any, error)
	}{{"cached", func() (any, error) { return services.TFTPPolicy() }}, {"rebuild", func() (any, error) { return services.buildTFTPPolicy() }}} {
		b.Run(tc.name, func(b *testing.B) {
			b.ReportAllocs()
			b.ResetTimer()
			for range b.N {
				policy, err := tc.call()
				if err != nil {
					b.Fatal(err)
				}
				tftpPolicyBenchmarkSink = policy
			}
		})
	}
}
