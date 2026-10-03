{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    escapeShellArg
    mkEnableOption
    mkIf
    mkOption
    optionalString
    types
    ;

  cfg = config.services.mbslave;
  pg = config.services.postgresql;

  settingsFormat = pkgs.formats.ini { };
  configFile = settingsFormat.generate "mbslave.conf" cfg.settings;

  # mbslave interpolates these into SQL unquoted.
  identifier = types.strMatching "[a-z_][a-z0-9_]*";

  stamp = "${cfg.stateDir}/initialised";
  marker = "${cfg.stateDir}/importing";
  dumps = "${cfg.stateDir}/dumps";

  # `public` belongs to pg_database_owner, and the pg_* and information_schema
  # schemas to the superuser, in every database.
  foreignSchemasSql = ''
    SELECT string_agg(nspname, ', ' ORDER BY nspname) FROM pg_namespace
    WHERE nspowner <> (SELECT oid FROM pg_roles WHERE rolname = '${cfg.user}')
      AND nspname NOT LIKE 'pg\_%'
      AND nspname NOT IN ('information_schema', 'public')
  '';

  readerRole = "${cfg.user}_reader";
  quotedReaders = lib.concatMapStringsSep ", " (r: "'${r}'") cfg.readers;

  # Idempotent, so both the import and every start of mbslave-grants apply it.
  # The default privileges extend the grant to tables that schema upgrades add.
  # dbmirror2 holds only the replication queue.
  grantsSql = pkgs.writeText "mbslave-grants.sql" ''
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${readerRole}') THEN
        CREATE ROLE ${readerRole} NOLOGIN;
      END IF;
    END
    $$;

    DO $$
    DECLARE
      s name;
      r name;
    BEGIN
      FOR s IN
        SELECT nspname FROM pg_namespace
        WHERE nspowner = '${cfg.user}'::regrole AND nspname <> 'dbmirror2'
      LOOP
        EXECUTE format('GRANT USAGE ON SCHEMA %I TO ${readerRole}', s);
        EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO ${readerRole}', s);
        EXECUTE format(
          'ALTER DEFAULT PRIVILEGES FOR ROLE ${cfg.user} IN SCHEMA %I GRANT SELECT ON TABLES TO ${readerRole}',
          s
        );
      END LOOP;

      FOR r IN
        SELECT m.rolname FROM pg_auth_members a JOIN pg_roles m ON m.oid = a.member
        WHERE a.roleid = '${readerRole}'::regrole
          AND m.rolname <> ALL (ARRAY[${quotedReaders}]::name[])
      LOOP
        EXECUTE format('REVOKE ${readerRole} FROM %I', r);
      END LOOP;
    END
    $$;

    ${lib.concatMapStrings (r: "GRANT ${readerRole} TO ${r};\n") cfg.readers}
  '';
  applyGrants = "psql -v ON_ERROR_STOP=1 -d ${cfg.database} -f ${grantsSql}";

  environment = {
    MBSLAVE_CONFIG = configFile;
    # Progress bars are noise in the journal. mbslave still logs each table.
    TQDM_DISABLE = "1";
  };

  hardening = {
    CapabilityBoundingSet = "";
    LockPersonality = true;
    NoNewPrivileges = true;
    PrivateDevices = true;
    PrivateTmp = true;
    ProcSubset = "pid";
    ProtectClock = true;
    ProtectControlGroups = true;
    ProtectHome = true;
    ProtectHostname = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    ProtectProc = "invisible";
    ProtectSystem = "strict";
    RestrictAddressFamilies = [
      "AF_UNIX"
      "AF_INET"
      "AF_INET6"
    ];
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    SystemCallArchitectures = "native";
    SystemCallFilter = [
      "@system-service"
      "~@privileged"
    ];
    UMask = "0077";
  };
in
{
  options.services.mbslave = {
    enable = mkEnableOption "a MusicBrainz database mirror, imported and kept up to date by mbslave";

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ../pkgs/mbslave.nix { postgresql = pg.package; };
      defaultText = lib.literalMD "mbslave from this flake, with the psql of `services.postgresql.package`";
      description = "The mbslave package to use.";
    };

    database = mkOption {
      type = identifier;
      default = "musicbrainz";
      description = "Name of the PostgreSQL database that holds the mirror.";
    };

    user = mkOption {
      type = identifier;
      default = "musicbrainz";
      description = ''
        System user and PostgreSQL role that own the mirror. The sync runs as
        this user.
      '';
    };

    stateDir = mkOption {
      type = types.path;
      default = "/var/lib/mbslave";
      description = ''
        Directory for the stamp that marks the initial import as done. The
        import also downloads the dumps (about 8 GB) here and deletes them
        when it completes.
      '';
    };

    importDumps = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether the initial import loads the latest full export. If false, it
        only creates the empty schema.
      '';
    };

    tokenFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/run/agenix/metabrainz-token";
      description = ''
        File that holds the MetaBrainz Live Data Feed access token. If null,
        the mirror never syncs after the initial import.
      '';
    };

    syncStartAt = mkOption {
      type = types.str;
      default = "hourly";
      description = ''
        When to apply new replication packets, in the format of
        {manpage}`systemd.time(7)`. MetaBrainz publishes one packet per hour.
      '';
    };

    ignoredSchemas = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [
        "event_art_archive"
        "wikidocs"
      ];
      description = "Schemas that mbslave neither imports nor replicates.";
    };

    ignoredTables = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Tables that mbslave neither imports nor replicates.";
    };

    readers = mkOption {
      type = types.listOf identifier;
      default = [ ];
      example = [ "alice" ];
      description = ''
        PostgreSQL roles that may read the mirror, through membership of the
        `<user>_reader` role. The module creates each role if it is missing.
        The default peer authentication lets the system user of the same name
        connect as it. Removing a name revokes its access but keeps the role.
      '';
    };

    settings = mkOption {
      type = settingsFormat.type;
      default = { };
      example = {
        musicbrainz.base_url = "https://metabrainz.org/api/musicbrainz/";
      };
      description = ''
        Extra mbslave.conf settings. See `mbslave.conf.default` upstream. The
        module sets the database entries and the ignore lists from the options
        above.
      '';
    };
  };

  config = mkIf cfg.enable {
    services.mbslave.settings = {
      database = {
        name = cfg.database;
        inherit (cfg) user;
        admin_user = pg.superUser;
      };
      schemas.ignore = lib.concatStringsSep "," cfg.ignoredSchemas;
      tables.ignore = lib.concatStringsSep "," cfg.ignoredTables;
    };

    services.postgresql = {
      enable = true;
      ensureUsers = map (name: { inherit name; }) ([ cfg.user ] ++ cfg.readers);
      # mbslave-init runs as the superuser but creates the tables as the mirror
      # role, so the superuser may also connect as that role.
      identMap = ''
        mbslave ${cfg.user} ${cfg.user}
        mbslave ${pg.superUser} ${cfg.user}
      '';
      authentication = ''
        local ${cfg.database} ${cfg.user} peer map=mbslave
      '';
    };

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.user;
    };
    users.groups.${cfg.user} = { };

    systemd.tmpfiles.settings.mbslave.${cfg.stateDir}.d = {
      user = pg.superUser;
      group = pg.superUser;
      mode = "0750";
    };

    systemd.services.mbslave-init = {
      description = "Initial import of the MusicBrainz mirror";
      # Type=exec ends the start job as soon as the import begins, so the
      # import (hours for a full export) holds up neither boot nor
      # `nixos-rebuild switch`. To retry after a failure, start the unit again.
      wantedBy = [ "multi-user.target" ];
      requires = [ "postgresql.target" ];
      wants = [ "network-online.target" ];
      after = [
        "postgresql.target"
        "network-online.target"
      ];
      unitConfig.ConditionPathExists = "!${stamp}";
      # A restart would kill an import in progress.
      restartIfChanged = false;
      path = [
        cfg.package
        pg.package
      ];
      inherit environment;
      serviceConfig = hardening // {
        Type = "exec";
        User = pg.superUser;
        Group = pg.superUser;
        ReadWritePaths = [ cfg.stateDir ];
      };
      script = ''
        if [ -e ${escapeShellArg marker} ]; then
          # A run that did not finish left a partial database behind. Other
          # services may keep their own schemas in the mirror database, so never
          # drop a database that holds a schema of another role.
          if [ "$(psql -tAc "SELECT 1 FROM pg_database WHERE datname = '${cfg.database}'")" = 1 ]; then
            foreign=$(psql -d ${cfg.database} -tAc "${foreignSchemasSql}")
            if [ -n "$foreign" ]; then
              echo "Database ${cfg.database} holds schemas that ${cfg.user} does not own: $foreign. Not dropping it to retry the import." >&2
              exit 1
            fi
          fi
          dropdb --if-exists ${cfg.database}
        elif [ "$(psql -tAc "SELECT 1 FROM pg_database WHERE datname = '${cfg.database}'")" = 1 ]; then
          echo "Database ${cfg.database} exists but mbslave-init did not create it. Not importing over it." >&2
          exit 1
        fi
        touch ${escapeShellArg marker}

        # mbslave downloads the dumps into the working directory.
        rm -rf ${escapeShellArg dumps}
        mkdir ${escapeShellArg dumps}
        cd ${escapeShellArg dumps}
        mbslave init --create-database ${optionalString (!cfg.importDumps) "--empty"}
        cd /
        rm -rf ${escapeShellArg dumps}

        # The replication triggers resolve unqualified names through the
        # search_path, which by default covers only a schema named after the role.
        psql -c "ALTER ROLE ${cfg.user} IN DATABASE ${cfg.database} SET search_path TO ${
          cfg.settings.schemas.musicbrainz or "musicbrainz"
        }, public"
        ${applyGrants}

        mv ${escapeShellArg marker} ${escapeShellArg stamp}
      '';
    };

    # Applies reader changes on boot and switch. mbslave-init applies them to a
    # fresh import itself.
    systemd.services.mbslave-grants = {
      description = "Grant read access to the MusicBrainz mirror";
      wantedBy = [ "multi-user.target" ];
      requires = [ "postgresql.target" ];
      after = [ "postgresql.target" ];
      unitConfig.ConditionPathExists = stamp;
      path = [ pg.package ];
      serviceConfig = hardening // {
        Type = "oneshot";
        RemainAfterExit = true;
        User = pg.superUser;
        Group = pg.superUser;
      };
      script = applyGrants;
    };

    # The point from which the mirror is imported and readable. Units that use
    # the mirror order on it rather than on mbslave-init, which reports success
    # as soon as a first import starts:
    #
    #   wantedBy = [ "mbslave-ready.target" ];
    #   after = [ "mbslave-ready.target" ];
    systemd.targets.mbslave-ready = {
      description = "MusicBrainz mirror imported and readable";
      wants = [ "mbslave-grants.service" ];
      after = [ "mbslave-grants.service" ];
    };

    # Reaches mbslave-ready.target at boot once the stamp exists, and on a new
    # host when the first import writes it.
    systemd.paths.mbslave-ready = {
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathExists = stamp;
        Unit = "mbslave-ready.target";
      };
    };

    systemd.services.mbslave-sync = mkIf (cfg.tokenFile != null) {
      description = "Apply MusicBrainz replication packets";
      requires = [ "postgresql.target" ];
      wants = [ "network-online.target" ];
      after = [
        "postgresql.target"
        "network-online.target"
      ];
      unitConfig.ConditionPathExists = stamp;
      startAt = cfg.syncStartAt;
      environment = environment // {
        MBSLAVE_MUSICBRAINZ_TOKEN_FILE = "%d/token";
      };
      # Without --keep-running, mbslave exits once no newer packet exists, and
      # fails on a schema change until the mirror is upgraded.
      serviceConfig = hardening // {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.user;
        ExecStart = "${lib.getExe cfg.package} sync";
        LoadCredential = "token:${cfg.tokenFile}";
      };
    };

    systemd.timers.mbslave-sync = mkIf (cfg.tokenFile != null) {
      timerConfig = {
        Persistent = true;
        RandomizedDelaySec = "5m";
      };
    };
  };
}
