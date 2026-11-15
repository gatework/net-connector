package bootstrap

import (
	"context"
	"testing"
	"time"

	"github.com/gatework/net-connector/config"
)

func TestTFTPUploadTimeoutConfiguration(t *testing.T) {
	for _, tc := range []struct {
		env  map[string]string
		want time.Duration
	}{{map[string]string{}, 180 * time.Second}, {map[string]string{"NC_TFTP_UPLOAD_TIMEOUT": "120"}, 120 * time.Second}} {
		p, e := config.Load(context.Background(), config.Options{Name: "backup", CWD: t.TempDir(), Home: t.TempDir(), Directories: []string{}, Environment: tc.env, Defaults: config.Defaults("tftp"), AllowMissing: true})
		if e != nil {
			t.Fatal(e)
		}
		s, e := New(p, nil)
		if e != nil {
			t.Fatal(e)
		}
		if s.ArchiveTimeouts().Upload != tc.want {
			t.Fatal(s.ArchiveTimeouts().Upload)
		}
	}
}

func TestTFTPPolicyIsResolvedOnceAtConstruction(t *testing.T) {
	policy, err := config.Load(context.Background(), config.Options{
		Name:        "backup",
		CWD:         t.TempDir(),
		Home:        t.TempDir(),
		Directories: []string{},
		Defaults:    config.Defaults("tftp"),
		Environment: map[string]string{"NC_TFTP_HOST": "192.0.2.50"},
	})
	if err != nil {
		t.Fatal(err)
	}
	services, err := New(policy, nil)
	if err != nil {
		t.Fatal(err)
	}
	first, err := services.TFTPPolicy()
	if err != nil {
		t.Fatal(err)
	}
	second, err := services.TFTPPolicy()
	if err != nil {
		t.Fatal(err)
	}
	if first != second {
		t.Fatal("TFTP policy was rebuilt for each workflow")
	}
	target, err := first.For("192.0.2.1", "h3c")
	if err != nil || target.Server != "192.0.2.50" {
		t.Fatalf("target=%+v error=%v", target, err)
	}
}

func TestArchiveTimeoutConfigurationAndLimits(t *testing.T) {
	for _, tc := range []struct {
		env     map[string]string
		invalid bool
	}{
		{map[string]string{"NC_TFTP_UPLOAD_TIMEOUT": "600", "NC_TFTP_ARCHIVE_PREPARE_TIMEOUT": "7.5", "NC_TFTP_ARCHIVE_VERIFY_TIMEOUT": "12", "NC_TFTP_ARCHIVE_CLEANUP_TIMEOUT": "2"}, false},
		{map[string]string{"NC_TFTP_UPLOAD_TIMEOUT": "1000000000000000000"}, true},
		{map[string]string{"NC_TFTP_ARCHIVE_VERIFY_TIMEOUT": "0"}, true},
		{map[string]string{"NC_TFTP_ARCHIVE_CLEANUP_TIMEOUT": "0.00000000001"}, true},
	} {
		p, err := config.Load(context.Background(), config.Options{Name: "backup", CWD: t.TempDir(), Home: t.TempDir(), Directories: []string{}, Environment: tc.env, Defaults: config.Defaults("tftp")})
		if err == nil {
			var s *Services
			s, err = New(p, nil)
			if err == nil && !tc.invalid {
				timeouts := s.ArchiveTimeouts()
				if timeouts.Upload != 600*time.Second || timeouts.Prepare != 7500*time.Millisecond || timeouts.Verify != 12*time.Second || timeouts.Cleanup != 2*time.Second {
					t.Fatal(timeouts)
				}
			}
		}
		if (err != nil) != tc.invalid {
			t.Fatalf("invalid=%v err=%v", tc.invalid, err)
		}
	}
}
