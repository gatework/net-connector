// Package terminal holds a CLI conversation with a network device.
//
// A device's dialect is declared as data in a Grammar: how it asks for
// credentials, what its prompts look like in each mode, which questions may
// be answered automatically and at what risk, which echoes mean a command
// was rejected, and which asynchronous log lines to ignore. Session is the
// one engine that interprets a Grammar over an expect stream: Login,
// Run and Execute never contain vendor branches.
//
// The engine is conservative:
//
//   - Each credential is sent at most once per login; a second prompt for
//     it is an authentication failure, so a wrong password never locks the
//     account by repetition.
//   - A question no Rule answers aborts the command (CodeInteraction)
//     instead of guessing; a disruptive Rule answers only when the command
//     allows that risk.
//   - A Procedure (save, commit, transfer) succeeds only on an affirmative
//     Success signature; reaching the prompt is not proof.
//   - Errors carry netops failure codes and stable reasons, never device
//     output.
//
// Every session is recorded by the expect engine (Options.Recorder), with
// credentials and Grammar.Redact matches masked.
package terminal
