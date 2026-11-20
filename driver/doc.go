// Package driver defines what a vendor platform is to the connector.
//
// A Driver is the minimum: a platform key and its terminal Grammar.
// Everything else a platform can do is an optional capability interface,
// discovered with a type assertion, so a platform declares exactly what it
// has evidence for and nothing more:
//
//	Classifier      recognizes the platform from inventory identity
//	ConfigReader    reads the running configuration
//	Saver           persists the running configuration
//	Committer       commits a candidate configuration (Junos, PAN-OS)
//	Checkpointer    takes and restores configuration checkpoints
//	Exporter        uploads the configuration to a TFTP/SCP server
//	LoginInspector  reads state such as an HA role from the login banner
//	ReadOnly        decides whether a command only reads
//
// Capabilities return data (commands and Procedures); the terminal engine
// executes and judges them, so vendor packages contain no expect loops.
package driver
