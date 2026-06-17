# Sample backend environment for the fixture project.
# Copy to env.sh (gitignored in a real checkout) and edit as needed:
#
#   cp sample.env.sh env.sh
#
# Format: bare KEY=VALUE per line (an `export ` prefix is allowed). Outer
# single/double quotes are stripped. Comments start with `#`.

# --- Database (Postgres) ---
# DB name: change `hello` to your database name; check-req.py compares the
# *DATASOURCES_DEFAULT_URL DB against its --database arg (default: hello).
DATASOURCES_DEFAULT_URL=jdbc:postgresql://localhost:5432/hello
DATASOURCES_DEFAULT_USERNAME=postgres
DATASOURCES_DEFAULT_PASSWORD=postgres
R2DBC_DATASOURCES_DEFAULT_URL=r2dbc:postgresql://localhost:5432/hello
R2DBC_DATASOURCES_DEFAULT_USERNAME=postgres
R2DBC_DATASOURCES_DEFAULT_PASSWORD=postgres

# --- Auth bootstrap (dev-only) ---
JWT_SECRET=dev-jwt-secret-change-in-production
API_KEY=dev-api-key-for-testing
