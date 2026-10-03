{
  fetchFromGitHub,
  lib,
  postgresql,
  python3Packages,
}:
python3Packages.buildPythonApplication rec {
  pname = "mbslave";
  version = "31.0.1";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "acoustid";
    repo = "mbslave";
    tag = "v${version}";
    hash = "sha256-3c+1ax3F4XnU0IA02EX3MeP9y2VPf0IH4DBdxti9QQA=";
  };

  # The upstream default fetches the dumps over plain HTTP, and `mbslave init`
  # has no flag to change it.
  postPatch = ''
    substituteInPlace mbslave/replication.py --replace-fail \
      http://ftp.musicbrainz.org/pub/musicbrainz/data/fullexport/ \
      https://data.metabrainz.org/pub/musicbrainz/data/fullexport/
  '';

  build-system = [ python3Packages.poetry-core ];

  dependencies = with python3Packages; [
    prometheus-client
    psycopg2
    six
    tqdm
  ];

  pythonRelaxDeps = [ "prometheus-client" ];

  # `mbslave init` shells out to `mbslave psql`, which runs `psql`.
  makeWrapperArgs = [
    "--prefix PATH : ${lib.makeBinPath [ postgresql ]}"
  ];

  nativeCheckInputs = [ python3Packages.pytestCheckHook ];

  # Needs a live database.
  disabledTestPaths = [ "mbslave/tests/test_docker_db.py" ];

  pythonImportsCheck = [ "mbslave.replication" ];

  meta = {
    description = "Replicate the MusicBrainz database into PostgreSQL";
    homepage = "https://github.com/acoustid/mbslave";
    changelog = "https://github.com/acoustid/mbslave/blob/v${version}/CHANGELOG.rst";
    license = lib.licenses.mit;
    mainProgram = "mbslave";
  };
}
