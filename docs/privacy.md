# Rallo privacy policy

Rallo is a macOS notes app by Razlio. It has no account, no Rallo server and no telemetry or
analytics. This page is the privacy policy that Google's consent screen links to.

## What Rallo stores

Everything is on your Mac, in `~/Library/Application Support/Razlio/Rallo/`: your notes, folders,
images, reminders, settings and a small diagnostics log (events and error text, never note
content). Secrets (the ClickUp token, a cloud voice API key, the Google Drive token) are kept in the
macOS Keychain. Razlio never receives any of it.

## When Rallo uses the network

Rallo talks to the internet only for features you turn on:

- **Update check:** once a day it asks GitHub for the latest Rallo release. You can turn it off in
  Settings → General.
- **ClickUp**, if you connect it: Rallo sends your ClickUp token to ClickUp's API once a minute to
  find direct messages waiting for you. It keeps only the sender's name.
- **Voice typing**, if you choose the Cloud engine: each phrase of audio goes to the provider you
  set up (Groq, OpenAI or your own), with your key. The Whisper engine downloads its model once
  from Hugging Face; Apple and Whisper otherwise work on your Mac.
- **Google Drive**, if you connect it (below).

## Google Drive

Settings → Data → Back up to → Google Drive uploads a backup of your notes to your own Google
Drive.

- **Access:** Rallo asks for the `https://www.googleapis.com/auth/drive.file` scope only. It can see
  and change only the files and folders Rallo itself creates, never the rest of your Drive.
- **Use:** Rallo creates a "Rallo Backups" folder, uploads your backup (a zip of your notes and
  images) at most once a day, and deletes its own older backups, keeping the two newest from each
  Mac. It also reads your account's email address to show who is connected.
- **The token** Google gives Rallo stays in the macOS Keychain on your Mac. Rallo shares neither the
  token nor your backups with anyone, and they never pass through a Razlio server: the uploads go
  from your Mac straight to Google.
- **Disconnecting:** Settings → Data → Disconnect revokes the token and deletes it from the Keychain.
  You can also remove Rallo at https://myaccount.google.com/permissions. Backups already in your
  Drive stay until you delete them.

Rallo's use of information from Google APIs follows the
[Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy),
including the Limited Use requirements.

## Contact

Questions or concerns: open an issue at https://github.com/Eyakub/Rallo/issues.
