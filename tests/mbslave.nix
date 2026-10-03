# Offline: the initial import creates the empty schema only, and a local HTTP
# server stands in for the MetaBrainz packet server.
{
  name = "mbslave";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ ../nixos/mbslave.nix ];

      services.postgresql.package = pkgs.postgresql_17;

      services.mbslave = {
        enable = true;
        importDumps = false;
        tokenFile = pkgs.writeText "metabrainz-token" "test-token";
        settings.musicbrainz.base_url = "http://127.0.0.1:8000/";
      };

      systemd.services.packets = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8000 --bind 127.0.0.1 --directory /var/empty";
      };
    };

  testScript = ''
    def mb(sql):
        return machine.succeed(f"sudo -u musicbrainz psql -d musicbrainz -tAc \"{sql}\"").strip()

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_file("/var/lib/mbslave/initialised", timeout=600)
    machine.wait_until_succeeds("systemctl show -P ActiveState mbslave-init | grep -x inactive")
    assert machine.succeed("systemctl show -P Result mbslave-init").strip() == "success"
    machine.fail("test -e /var/lib/mbslave/dumps")

    with subtest("the schema exists and belongs to the mirror role"):
        schemas = mb(
            "SELECT count(*) FROM information_schema.schemata WHERE schema_name IN "
            "('musicbrainz', 'statistics', 'cover_art_archive', 'event_art_archive', "
            "'wikidocs', 'documentation', 'dbmirror2')"
        )
        assert schemas == "7", schemas
        encoding = mb("SELECT pg_encoding_to_char(encoding) FROM pg_database WHERE datname = 'musicbrainz'")
        assert encoding == "UTF8", encoding
        for table in ["artist", "release_group", "recording", "isrc", "replication_control"]:
            owner = mb(f"SELECT tableowner FROM pg_tables WHERE schemaname = 'musicbrainz' AND tablename = '{table}'")
            assert owner == "musicbrainz", f"{table}: {owner!r}"

    with subtest("only peer auth with the mbslave map admits other users"):
        machine.fail("sudo -u nobody psql -U musicbrainz -d musicbrainz -c 'SELECT 1'")

    with subtest("the sync timer is configured"):
        machine.succeed("systemctl is-active mbslave-sync.timer")
        timer = machine.succeed("systemctl show -P TimersCalendar mbslave-sync.timer")
        assert "*-*-* *:00:00" in timer, timer
        assert machine.succeed("systemctl show -P Persistent mbslave-sync.timer").strip() == "yes"

    with subtest("sync reads the token through the unit credential"):
        machine.succeed(
            "sudo -u postgres psql -d musicbrainz -c "
            "'INSERT INTO musicbrainz.replication_control "
            "(current_schema_sequence, current_replication_sequence) VALUES (31, 100)'"
        )
        machine.wait_for_open_port(8000)
        machine.succeed("systemctl start mbslave-sync")
        assert machine.succeed("systemctl show -P Result mbslave-sync").strip() == "success"
        machine.succeed("journalctl -u packets | grep -F 'GET /replication-101-v2.tar.bz2?token=test-token'")

    with subtest("init does not run again once the stamp exists"):
        machine.succeed("systemctl start mbslave-init")
        assert machine.succeed("systemctl show -P ConditionResult mbslave-init").strip() == "no"

    with subtest("init replaces the partial database of an interrupted run"):
        machine.succeed("mv /var/lib/mbslave/initialised /var/lib/mbslave/importing")
        machine.succeed("systemctl start mbslave-init")
        machine.wait_for_file("/var/lib/mbslave/initialised", timeout=600)
        assert mb("SELECT count(*) FROM musicbrainz.replication_control") == "0"

    with subtest("init refuses a database that it did not create"):
        machine.succeed("rm /var/lib/mbslave/initialised")
        machine.succeed("systemctl start mbslave-init")
        machine.wait_until_succeeds("systemctl show -P Result mbslave-init | grep -x exit-code")
        machine.succeed("journalctl -u mbslave-init | grep -F 'mbslave-init did not create it'")
  '';
}
