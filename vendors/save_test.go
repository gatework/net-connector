package vendors

import (
	"errors"
	"testing"

	"github.com/gatework/net-connector/connector"
)

func TestPlatformSaveRequiresDeclaredPositiveEvidence(t *testing.T) {
	for _, tc := range []struct {
		vendor, prompt, command, confirmation string
	}{
		{"h3c", "<core>", "save force", "Saved the current configuration to mainboard device successfully."},
		{"h3c_wireless", "[AC]", "save force", "Saved the current configuration to mainboard device successfully."},
		{"cisco_ios", "router#", "copy running-config startup-config", "[OK]"},
		{"cisco_nxos", "nexus#", "copy run start", "Copy complete."},
		{"hillstone", "stone#", "save all", "Saving configuration is finished."},
		{"centec", "Switch#", "copy running-config startup-config", "[OK]"},
	} {
		t.Run(tc.vendor, func(t *testing.T) {
			d, check := dialogue(t, tc.vendor, tc.prompt, []exchange{{tc.command + "\n", tc.confirmation + "\r\n" + tc.prompt}})
			if _, err := d.SaveConfig(t.Context(), connector.ExecuteOptions{}); err != nil {
				t.Fatalf("declared save confirmation rejected: %v", err)
			}
			check()
		})
	}
	t.Run("huawei", func(t *testing.T) {
		d, check := dialogue(t, "huawei", "<Huawei>", []exchange{
			{"su\n", "privilege level is 3\n<Huawei>"},
			{"save force\n", "Save the configuration successfully.\r\n<Huawei>"},
		})
		if _, err := d.SaveConfig(t.Context(), connector.ExecuteOptions{}); err != nil {
			t.Fatalf("declared save confirmation rejected: %v", err)
		}
		check()
	})
}

func TestFortinetPromptAloneDoesNotConfirmSave(t *testing.T) {
	const prompt = "FGT (root) # "
	d, check := dialogue(t, "fortinet", prompt, []exchange{{"execute cfg save\n", prompt}})
	if _, err := d.SaveConfig(t.Context(), connector.ExecuteOptions{}); !errors.Is(err, connector.ErrUnconfirmed) {
		t.Fatalf("prompt treated as save confirmation: %v", err)
	}
	check()
}
