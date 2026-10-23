# Security

Atlas keeps AWS access keys and uses them to read and change infrastructure. A security bug here can cost money or data. Thank you for helping to find them.

## Supported versions

| Version | Security fixes |
|---|---|
| Latest stable ([Latest](https://github.com/viniciuslopesgit/Atlas/releases/latest)) | Yes |
| Latest beta (pre-release) | Yes |
| Older, and the Windows app (1.x) | No: update to the latest stable |

## How to report

**Do not open a public issue** for a vulnerability.

Use **Security ▸ Report a vulnerability** in the [repository](https://github.com/viniciuslopesgit/Atlas/security). If that option does not show, write to contact.viniciuslopes@gmail.com with "Atlas security" in the subject.

Include, if you can:

- the Atlas and macOS versions, and whether it is Apple silicon or Intel;
- the steps to reproduce, preferably against a test AWS account;
- the impact: what can be read, changed or run, and with whose credentials.

## What counts as a vulnerability

- An access key leaving the Keychain other than to sign a request to AWS: on a command line, in a file, in a log, or sent anywhere else.
- Changing AWS resources without the user's confirmation, or something other than what was confirmed.
- Running commands or writing files outside what the user chose, for example from a bucket key, a tag value or an AWS response.
- Terraform configuration that Atlas generates being altered by values from the account (HCL injection).
- Bypassing the checksum or signature check of the updater.
