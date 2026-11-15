package topology_test

import (
	"fmt"
	"strings"
	"testing"

	"github.com/gatework/net-connector/topology"

	"github.com/gatework/net-connector/vendors"
)

func BenchmarkParseNeighbors1000(b *testing.B) {
	var input strings.Builder
	input.WriteString("Local Interface Chassis ID Port ID System Name\n")
	for i := 1; i <= 1000; i++ {
		fmt.Fprintf(&input, "GE1/0/%d 000f-e25d-%04x GE1/0/%d peer-%04d\n", i, i, i+1, i)
	}
	output := input.String()
	if neighbors, err := topology.ParseNeighbors(neighborPolicyFor(b, "h3c"), output); err != nil || len(neighbors) != 1000 {
		b.Fatalf("fixture neighbors=%d error=%v", len(neighbors), err)
	}
	b.ReportAllocs()
	b.SetBytes(int64(len(output)))
	b.ResetTimer()
	for range b.N {
		if _, err := topology.ParseNeighbors(neighborPolicyFor(b, "h3c"), output); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkBuildPlan1000(b *testing.B) {
	peers := make([]topology.Neighbor, 1000)
	descriptions := make(map[string]string, len(peers))
	for i := range peers {
		peer := topology.Neighbor{
			LocalInterface:    fmt.Sprintf("GigabitEthernet1/0/%d", i+1),
			NeighborName:      fmt.Sprintf("peer-%04d", i),
			NeighborInterface: "GigabitEthernet1/0/1",
			ChassisID:         fmt.Sprintf("000f-e25d-%04x", i),
			Protocol:          "lldp",
		}
		peers[i] = peer
		descriptions[topology.InterfaceKey(peer.LocalInterface)] = "old"
	}
	options := topology.FormatOptions{Formatter: func(peer topology.Neighbor) (string, error) {
		return "peer-" + peer.NeighborName, nil
	}}
	if _, err := topology.BuildPlan(vendors.NewBuiltinRegistry(), "192.0.2.1", "h3c", peers, descriptions, options); err != nil {
		b.Fatal(err)
	}
	b.ReportAllocs()
	b.ResetTimer()
	for range b.N {
		if _, err := topology.BuildPlan(vendors.NewBuiltinRegistry(), "192.0.2.1", "h3c", peers, descriptions, options); err != nil {
			b.Fatal(err)
		}
	}
}
