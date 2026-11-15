package transfer_test

import (
	"errors"
	"testing"

	"github.com/gatework/net-connector/transfer"

	"github.com/gatework/net-connector/vendors"
)

func TestPolicyHostOverridesAndNullableVendorValues(t *testing.T) {
	p, e := transfer.NewPolicy(transfer.PolicyOptions{Server: "SERVER", Servers: map[string]string{"2001:db8::1": "other"}, SourceFiles: map[string]any{"huawei": map[string]any{"default": "flash:/startup.cfg", "hosts": map[string]any{"2001:db8::1": nil}}}, VRFs: map[string]any{"cisco_nxos": "blue"}}, vendors.NewBuiltinRegistry())
	if e != nil {
		t.Fatal(e)
	}
	a, e := p.For("192.0.2.1", "huawei")
	if e != nil || a.Server != "server" || a.SourceFile != "flash:/startup.cfg" {
		t.Fatal(a, e)
	}
	b, e := p.For("2001:db8::1", "huawei")
	if e != nil || b.Server != "other" || b.SourceFile != "" {
		t.Fatal(b, e)
	}
}
func TestPolicyMaterializesCiscoNXOSDriverDefaultVRF(t *testing.T) {
	for _, tc := range []struct {
		name string
		vrfs map[string]any
		want string
	}{{name: "driver default", want: "management"}, {name: "configured override", vrfs: map[string]any{"cisco_nxos": "blue"}, want: "blue"}} {
		t.Run(tc.name, func(t *testing.T) {
			p, err := transfer.NewPolicy(transfer.PolicyOptions{Server: "192.0.2.9", VRFs: tc.vrfs}, vendors.NewBuiltinRegistry())
			if err != nil {
				t.Fatal(err)
			}
			target, err := p.For("192.0.2.1", "cisco_nxos")
			if err != nil || target.VRF != tc.want {
				t.Fatalf("target VRF = %q, error = %v; want %q", target.VRF, err, tc.want)
			}
		})
	}
}

func TestPolicyUsesPlatformTransferRequirements(t *testing.T) {
	registry := vendors.NewBuiltinRegistry()
	withoutServer, err := transfer.NewPolicy(transfer.PolicyOptions{}, registry)
	if err != nil {
		t.Fatal(err)
	}
	if target, targetErr := withoutServer.For("192.0.2.1", "palo_alto"); targetErr != nil || target.Server != "" {
		t.Fatalf("missing server should remain a caller validation error: %#v, %v", target, targetErr)
	}
	withoutRoot, err := transfer.NewPolicy(transfer.PolicyOptions{Server: "192.0.2.9"}, registry)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = withoutRoot.For("192.0.2.1", "palo_alto"); !errors.Is(err, transfer.ErrInvalid) {
		t.Fatalf("Palo Alto target without a verification root: %v", err)
	}
	withRoot, err := transfer.NewPolicy(transfer.PolicyOptions{Server: "192.0.2.9", Root: "/tmp/archive"}, registry)
	if err != nil {
		t.Fatal(err)
	}
	target, err := withRoot.For("192.0.2.1", "palo_alto")
	if err != nil || target.Root != "/tmp/archive" {
		t.Fatalf("Palo Alto target = %#v, error = %v", target, err)
	}
	if err = transfer.Validate(registry, "huawei", "192.0.2.1", transfer.TFTPOptions{Server: "192.0.2.9", Path: "backup.cfg"}); !errors.Is(err, transfer.ErrSourceFileRequired) {
		t.Fatalf("Huawei source file requirement: %v", err)
	}
}

func TestPolicyRejectsNilConcreteRegistry(t *testing.T) {
	var registry *vendors.Registry
	if _, err := transfer.NewPolicy(transfer.PolicyOptions{}, registry); !errors.Is(err, transfer.ErrInvalid) {
		t.Fatalf("nil concrete registry error = %v", err)
	}
}

func TestPolicyRejectsSharedRootsAndUnsafeUnusedPolicies(t *testing.T) {
	for _, o := range []transfer.PolicyOptions{
		{Roots: map[string]string{"a": "/tmp/root", "b": "/tmp/root"}},
		{Servers: map[string]string{"192.0.2.1/24": "a"}},
		{VRFs: map[string]any{"cisco_ios": "default"}},
		{SourceInterfaces: map[string]any{"radware": "bad"}},
		{Root: "ssh://root:secret@server/path"},
	} {
		if _, e := transfer.NewPolicy(o, vendors.NewBuiltinRegistry()); e == nil {
			t.Fatal("accepted invalid policy")
		}
	}
}
