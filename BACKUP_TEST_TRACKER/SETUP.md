# Backup & Recovery Test Tracker — PocketBase setup

## 1. Install PocketBase on the Ubuntu VM

```sh
cd /opt
sudo mkdir pocketbase && cd pocketbase
sudo wget https://github.com/pocketbase/pocketbase/releases/download/v0.22.21/pocketbase_0.22.21_linux_amd64.zip
sudo unzip pocketbase_0.22.21_linux_amd64.zip
sudo chmod +x pocketbase
```

(Check latest version at https://github.com/pocketbase/pocketbase/releases)

## 2. Drop the HTML in

PocketBase auto-serves any files placed in `pb_public/`:

```sh
sudo mkdir -p /opt/pocketbase/pb_public
sudo cp /path/to/index.html /opt/pocketbase/pb_public/index.html
```

## 3. First run — create the admin account

```sh
cd /opt/pocketbase
sudo ./pocketbase serve --http=0.0.0.0:8090
```

Open `http://<vm-ip>:8090/_/` in your browser. Create an admin email/password.

## 4. Create the `tests` collection

In the admin UI → **Collections** → **New collection** → name it `tests`.

Add these fields (all "required" unless noted):

| Field         | Type     | Options                                                    |
|---------------|----------|------------------------------------------------------------|
| test_date     | Date     | start date                                                 |
| end_date      | Date     | not required — leave blank for single-day                  |
| os_platform   | Select   | values: AIX, IBMI, x86                                     |
| customer      | Text     |                                                            |
| technician    | Text     |                                                            |
| test_type     | Select   | values: OnSite, Remote                                     |
| status        | Select   | values: Scheduled, InProgress, Complete, Failed            |
| notes         | Text     | not required                                               |

## 5. Create the `holidays` collection

In the admin UI → **Collections** → **New collection** → name it `holidays`.

Add these fields:

| Field       | Type | Options      |
|-------------|------|--------------|
| technician  | Text | required     |
| start_date  | Date | required     |
| end_date    | Date | required     |
| notes       | Text | not required |

## 6. Create user accounts

In the admin UI → **Collections** → **users** → **New record**.

Add one record per team member:

| Field    | Value                  |
|----------|------------------------|
| email    | technician@example.com |
| password | (set a strong password)|
| verified | ✓ tick this            |

Repeat for each user who needs access. Users can only be created/deleted by the PocketBase admin — there is no self-registration.

## 7. Lock the collection API rules

Both `tests` and `holidays` collections must require auth, otherwise the API is still open to unauthenticated requests even with the login screen in place.

In the admin UI → **Collections** → select `tests` → **API Rules** tab.

Set all 5 rules (list, view, create, update, delete) to:

```
@request.auth.id != ""
```

Repeat for the `holidays` collection.

Once set, any request without a valid `Authorization` token returns 401 and the app redirects to the login screen automatically.

## 8. Run as a systemd service

Create `/etc/systemd/system/pocketbase.service`:

```ini
[Unit]
Description=PocketBase
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/pocketbase
ExecStart=/opt/pocketbase/pocketbase serve --http=0.0.0.0:8090
Restart=always

[Install]
WantedBy=multi-user.target
```

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now pocketbase
```

## 9. Access

Team members open `http://<vm-ip>:8090/` — they get the form + table + year calendar.
Admin UI lives at `http://<vm-ip>:8090/_/`.

## Backups

Both collections live in the same SQLite file: `/opt/pocketbase/pb_data/data.db`

Nightly cron:

```sh
0 2 * * * cp /opt/pocketbase/pb_data/data.db /backup/pocketbase-$(date +\%F).db
```

To also get a JSON export of each collection (useful for scripted restores):

```sh
0 2 * * * sqlite3 /opt/pocketbase/pb_data/data.db \
  "SELECT json_group_array(json_object('id',id,'technician',technician,'start_date',start_date,'end_date',end_date,'notes',notes)) FROM holidays" \
  > /backup/holidays-$(date +\%F).json

0 2 * * * sqlite3 /opt/pocketbase/pb_data/data.db \
  "SELECT json_group_array(json_object('id',id,'test_date',test_date,'end_date',end_date,'os_platform',os_platform,'customer',customer,'technician',technician,'test_type',test_type,'status',status,'notes',notes)) FROM tests" \
  > /backup/tests-$(date +\%F).json
```

## Optional: HTTPS + nicer URL

Put nginx in front and point a DNS name at it; PocketBase can also do TLS directly via
`--https=:443` with Let's Encrypt if the VM is publicly reachable.# Backup & Recovery Test Tracker — PocketBase setup

## 1. Install PocketBase on the Ubuntu VM

```sh
cd /opt
sudo mkdir pocketbase && cd pocketbase
sudo wget https://github.com/pocketbase/pocketbase/releases/download/v0.22.21/pocketbase_0.22.21_linux_amd64.zip
sudo unzip pocketbase_0.22.21_linux_amd64.zip
sudo chmod +x pocketbase
```

(Check latest version at https://github.com/pocketbase/pocketbase/releases)

## 2. Drop the HTML in

PocketBase auto-serves any files placed in `pb_public/`:

```sh
sudo mkdir -p /opt/pocketbase/pb_public
sudo cp /path/to/index.html /opt/pocketbase/pb_public/index.html
```

## 3. First run — create the admin account

```sh
cd /opt/pocketbase
sudo ./pocketbase serve --http=0.0.0.0:8090
```

Open `http://<vm-ip>:8090/_/` in your browser. Create an admin email/password.

## 4. Create the `tests` collection

In the admin UI → **Collections** → **New collection** → name it `tests`.

Add these fields (all "required" unless noted):

| Field         | Type     | Options                                    |
|---------------|----------|--------------------------------------------|
| test_date     | Date     | start date                                 |
| end_date      | Date     | not required — leave blank for single-day  |
| os_platform   | Select   | values: AIX, IBMI, x86                     |
| customer      | Text     |                                            |
| technician    | Text     |                                            |
| test_type     | Select   | values: OnSite, Remote                     |
| status        | Select   | values: Scheduled, InProgress, Complete, Failed |
| notes         | Text     | not required                               |

Then go to the collection's **API Rules** tab. For an internal-only tool where everyone on the LAN can read/write, set all 5 rules (list, view, create, update, delete) to an empty string (means "anyone"). If you want auth, leave them as `@request.auth.id != ""` and create PocketBase users instead.

## 5. Run as a systemd service

Create `/etc/systemd/system/pocketbase.service`:

```ini
[Unit]
Description=PocketBase
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/pocketbase
ExecStart=/opt/pocketbase/pocketbase serve --http=0.0.0.0:8090
Restart=always

[Install]
WantedBy=multi-user.target
```

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now pocketbase
```

## 6. Access

Team members open `http://<vm-ip>:8090/` — they get the form + table.
Admin UI lives at `http://<vm-ip>:8090/_/`.

## Backups

The entire database is `/opt/pocketbase/pb_data/data.db` (SQLite).
Nightly cron:

```sh
0 2 * * * cp /opt/pocketbase/pb_data/data.db /backup/pocketbase-$(date +\%F).db
```

## Optional: HTTPS + nicer URL

Put nginx in front and point a DNS name at it; PocketBase can also do TLS directly via `--https=:443` with Let's Encrypt if the VM is reachable.
