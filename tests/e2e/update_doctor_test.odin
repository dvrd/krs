package e2e

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import krs "../../src"
import "../fixtures"

@(test)
doctor_keeps_all_upgrades_when_tests_pass :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.upgrades_fixture(&fixture)

	result := fixtures.run(&fixture, "", "update", "-u", "--doctor", "--yes", "--doctor-test=true")
	fixtures.expect_ok(&fixture, result)
	fixtures.expect_release(&fixture, "beta", "v0.5.0")
	fixtures.expect_release(&fixture, "gamma", "v0.1.1")
	fixtures.expect_contains(&fixture, result.out, "pass the tests")
}

@(test)
doctor_reverts_the_upgrade_that_breaks :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.upgrades_fixture(&fixture)

	test := fmt.aprintf("--doctor-test=%s", fixtures.beta_breaks_on(fixture.shared))
	result := fixtures.run(&fixture, "", "update", "-u", "--doctor", "--yes", test)
	testing.expectf(t, result.code == 1, "exit %d\nout: %s\nerr: %s", result.code, result.out, result.err)
	fixtures.expect_release(&fixture, "beta", "v0.4.0")
	fixtures.expect_release(&fixture, "gamma", "v0.1.1")
	packages := fixtures.packages_text(&fixture)
	fixtures.expect_contains(&fixture, packages, "\"v0.4.0\"")
	fixtures.expect_contains(&fixture, packages, "\"v0.1.1\"")
	testing.expect(t, !strings.contains(packages, "v0.5.0"))
	fixtures.expect_contains(&fixture, result.out, "breaks the tests")
	fixtures.expect_contains(&fixture, result.out, "passes the tests")
}

@(test)
doctor_asks_for_consent_on_a_shared_root :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.upgrades_fixture(&fixture)
	packages := fixtures.packages_text(&fixture)
	manifest := fixtures.manifest_text(&fixture)

	result := fixtures.run(&fixture, "", "update", "-u", "--doctor", "--doctor-test=true")
	fixtures.expect_failure(&fixture, result, "confirmation is needed")
	fixtures.expect_contains(&fixture, result.out, "every project on this Odin root sees them")
	testing.expect_value(t, fixtures.packages_text(&fixture), packages)
	testing.expect_value(t, fixtures.manifest_text(&fixture), manifest)
}

@(test)
doctor_runs_the_install_command :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.upgrades_fixture(&fixture)

	result := fixtures.run(&fixture, "", "update", "-u", "--doctor", "--yes", "--doctor-install=touch doctor-installed",
		"--doctor-test=test -f doctor-installed")
	fixtures.expect_ok(&fixture, result)
	testing.expect(t, os.exists(krs.path_join(fixture.project, "doctor-installed")))
	fixtures.expect_release(&fixture, "beta", "v0.5.0")
}

@(test)
doctor_restores_the_lockfile_byte_for_byte :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.upgrades_fixture(&fixture)
	packages := fixtures.packages_text(&fixture)
	manifest := fixtures.manifest_text(&fixture)

	either := fmt.aprintf(
		"--doctor-test=! grep -q 'v0.5.0' %s/beta/beta.odin && ! grep -q 'v0.1.1' %s/gamma/gamma.odin",
		fixture.shared,
		fixture.shared,
	)
	result := fixtures.run(&fixture, "", "update", "-u", "--doctor", "--yes", either)
	testing.expectf(t, result.code == 1, "exit %d\nout: %s\nerr: %s", result.code, result.out, result.err)
	testing.expect_value(t, fixtures.packages_text(&fixture), packages)
	testing.expect_value(t, fixtures.manifest_text(&fixture), manifest)
	fixtures.expect_release(&fixture, "beta", "v0.4.0")
	fixtures.expect_release(&fixture, "gamma", "v0.1.0")

	// beta v0.5.0 records gamma v0.1.1, so upgrading beta alone moves gamma
	// too; the revert must move gamma back.
	moved := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&moved)

	fixtures.library_release(&moved, "beta", "v0.4.0")
	fixtures.library_release(&moved, "gamma", "v0.1.0")
	fixtures.project_imports(&moved, "beta", "gamma")
	fixtures.expect_ok(&moved, fixtures.run(&moved, "", "install", "--yes"))
	fixtures.library_release(&moved, "gamma", "v0.1.1")
	fixtures.library_recording(&moved, "beta", "v0.5.0", "gamma", "v0.1.1")
	moved_packages := fixtures.packages_text(&moved)

	test := fmt.aprintf("--doctor-test=%s", fixtures.beta_breaks_on(moved.shared))
	only_beta := fixtures.run(&moved, "", "update", "-u", "--doctor", "--yes", test, "beta")
	testing.expectf(t, only_beta.code == 1, "exit %d\nout: %s\nerr: %s", only_beta.code, only_beta.out, only_beta.err)
	fixtures.expect_contains(&moved, only_beta.out, "breaks the tests")
	// gamma is not a candidate: only beta's trial install moved it.
	fixtures.expect_contains(&moved, only_beta.out, "v0.1.1")
	testing.expect_value(t, fixtures.packages_text(&moved), moved_packages)
	testing.expect(t, !strings.contains(fixtures.packages_text(&moved), "v0.1.1"))
	fixtures.expect_release(&moved, "beta", "v0.4.0")
	fixtures.expect_release(&moved, "gamma", "v0.1.0")
}

@(test)
doctor_byte_check_ignores_the_install_hook :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.upgrades_fixture(&fixture)

	// The hook changes the lockfile on every run, the baseline included; the
	// bytes a revert must match are the ones from before the baseline.
	test := fmt.aprintf("--doctor-test=%s", fixtures.beta_breaks_on(fixture.shared))
	result := fixtures.run(&fixture, "", "update", "-u", "--doctor", "--yes", "--doctor-install=printf ' ' >> .krs/packages.json", test)
	testing.expectf(t, result.code == 1, "exit %d\nout: %s\nerr: %s", result.code, result.out, result.err)
	testing.expectf(t, !strings.contains(result.err, "byte for byte"), "unexpected byte check failure: %s", result.err)
	fixtures.expect_contains(&fixture, result.out, "breaks the tests")
	fixtures.expect_release(&fixture, "beta", "v0.4.0")
}

@(test)
doctor_refuses_a_lockfile_behind_the_root :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	a := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&a)

	fixtures.library_release(&a, "beta", "v0.1.0")
	fixtures.project_imports(&a, "beta")
	fixtures.expect_ok(&a, fixtures.run(&a, "", "install", "--yes"))

	// Project B, on the same Odin root, moves beta to a compatible release.
	b := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&b)
	b.root = a.root
	b.shared = a.shared
	b.home = a.home
	b.sources = a.sources
	fixtures.project_imports(&b, "beta")
	fixtures.expect_ok(&b, fixtures.run(&b, "", "install", "--yes"))
	fixtures.library_release(&a, "beta", "v0.1.1")
	fixtures.expect_ok(&b, fixtures.run(&b, "", "update", "-u", "--yes"))
	fixtures.expect_release(&a, "beta", "v0.1.1")

	packages := fixtures.packages_text(&a)
	manifest := fixtures.manifest_text(&a)
	result := fixtures.run(&a, "", "update", "-u", "--doctor", "--yes", "--doctor-test=true")
	fixtures.expect_failure(&a, result, "run krs install first")
	testing.expect_value(t, fixtures.packages_text(&a), packages)
	testing.expect_value(t, fixtures.manifest_text(&a), manifest)
}

@(test)
doctor_reports_a_failed_restore :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.upgrades_fixture(&fixture)

	// While beta v0.5.0 is installed, the tests fail and take beta's
	// repository away, so the revert cannot find beta v0.4.0.
	beta := krs.path_join(fixture.sources, "beta")
	gone := krs.path_join(fixture.sources, "beta.gone")
	test := fmt.aprintf(
		"--doctor-test=if grep -q 'RELEASE :: \"v0.5.0\"' %s/beta/beta.odin; then mv %s %s; exit 1; fi",
		fixture.shared,
		beta,
		gone,
	)
	result := fixtures.run(&fixture, "", "update", "-u", "--doctor", "--yes", test)
	testing.expectf(t, result.code == 1, "exit %d\nout: %s\nerr: %s", result.code, result.out, result.err)
	fixtures.expect_contains(&fixture, result.err, "could not restore the previous versions")
	// krs prints the project as given and the Odin root resolved by state_lock
	// (on macOS /var becomes /private/var), so resolve only the root here.
	root, _ := os.get_absolute_path(fixture.root, context.temp_allocator)
	fixtures.expect_contains(&fixture, result.err, fmt.tprintf("cd '%s' && krs update -u --yes --root='%s' beta@v0.4.0 gamma@v0.1.0", fixture.project, root))

	// The printed command, end to end.
	testing.expect(t, os.rename(gone, beta) == nil)
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "update", "-u", "--yes", "beta@v0.4.0", "gamma@v0.1.0"))
	fixtures.expect_release(&fixture, "beta", "v0.4.0")
	fixtures.expect_release(&fixture, "gamma", "v0.1.0")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--frozen"))
}

@(test)
doctor_needs_a_passing_baseline :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.upgrades_fixture(&fixture)
	packages := fixtures.packages_text(&fixture)
	manifest := fixtures.manifest_text(&fixture)

	result := fixtures.run(&fixture, "", "update", "-u", "--doctor", "--yes", "--doctor-test=false")
	fixtures.expect_failure(&fixture, result, "needs a passing baseline")
	testing.expect_value(t, fixtures.packages_text(&fixture), packages)
	testing.expect_value(t, fixtures.manifest_text(&fixture), manifest)
	fixtures.expect_release(&fixture, "beta", "v0.4.0")
}

@(test)
doctor_times_out_and_reverts :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.release_beta_upgrade(&fixture)
	before := fixtures.packages_text(&fixture)

	// `exec` makes the killed process the sleep itself, so nothing is left running.
	test := fmt.tprintf("--doctor-test=if grep -q 'RELEASE :: \"v0.2.0\"' %s/beta/beta.odin; then exec sleep 30; fi", fixture.shared)
	result := fixtures.run(&fixture, "", "update", "-u", "--doctor", "--yes", "--doctor-timeout=1s", test)
	testing.expectf(t, result.code == 1, "exit %d\nout: %s\nerr: %s", result.code, result.out, result.err)
	fixtures.expect_contains(&fixture, result.out, "timed out")
	fixtures.expect_release(&fixture, "beta", "v0.1.0")
	testing.expect_value(t, fixtures.packages_text(&fixture), before)
}

@(test)
doctor_timeout_stops_the_whole_command :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.release_beta_upgrade(&fixture)
	marker := krs.path_join(fixture.base, "krs-032-marker")
	// Only the trial with beta v0.2.0 hangs. Its background child would
	// outlive a killed shell and create the marker.
	test := fmt.aprintf(
		"--doctor-test=if grep -q 'RELEASE :: \"v0.2.0\"' %s/beta/beta.odin; then ( sleep 4; touch '%s' ) & sleep 37; fi",
		fixture.shared,
		marker,
	)
	result := fixtures.run(&fixture, "", "update", "-u", "--doctor", "--yes", "--doctor-timeout=1s", test)
	testing.expectf(t, result.code == 1, "exit %d\nout: %s\nerr: %s", result.code, result.out, result.err)
	fixtures.expect_contains(&fixture, result.out, "timed out")
	time.sleep(5 * time.Second)
	testing.expectf(t, !os.exists(marker), "a child of the test command survived the timeout")
	fixtures.expect_release(&fixture, "beta", "v0.1.0")
}

@(test)
doctor_recovery_command_shows_at_quiet_levels :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.release_beta_upgrade(&fixture)
	result := fixtures.run(&fixture, "", "update", "-u", "--doctor", "--yes", "--doctor-test=true", "--loglevel", "error")
	fixtures.expect_contains(&fixture, result.err, "if this run stops early, restore with:")
}

@(test)
doctor_flags_are_checked :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.upgrades_fixture(&fixture)

	Misuse :: struct {
		arguments: []string,
		message:   string,
	}
	cases := []Misuse {
		{{"update", "--doctor"}, "--doctor needs -u"},
		{{"install", "--doctor"}, "--doctor only applies to update"},
		{{"update", "-u", "--doctor-test=true"}, "--doctor-test needs --doctor"},
		{{"update", "-u", "--doctor-install", "true"}, "--doctor-install needs --doctor"},
		{{"update", "-u", "--doctor", "--install=never"}, "--install=never cannot be combined"},
		{{"update", "-u", "--doctor", "--pin"}, "--doctor and --pin cannot be combined"},
		{{"update", "-u", "--doctor", "-g"}, "--doctor and --global cannot be combined"},
		{{"update", "-u", "--doctor", "-j"}, "JSON output cannot be combined"},
		{{"update", "-u", "-d", "--json-upgraded"}, "JSON output cannot be combined"},
		{{"update", "-i", "--doctor"}, "--doctor and -i cannot be combined"},
		{{"update", "-u", "--doctor", "--doctor-timeout=0s"}, "0s is not a timeout"},
		{{"update", "-u", "--doctor", "--doctor-timeout=5"}, "5 is not a timeout"},
		{{"update", "-u", "--doctor-timeout=1m"}, "--doctor-timeout needs --doctor"},
	}
	for misuse in cases {
		result := fixtures.run(&fixture, "", ..misuse.arguments)
		testing.expectf(t, result.code == krs.EXIT_USAGE, "%v: exit %d, err: %s", misuse.arguments, result.code, result.err)
		fixtures.expect_contains(&fixture, result.err, misuse.message)
	}
	fixtures.expect_release(&fixture, "beta", "v0.4.0")
}
