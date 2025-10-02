# RapidPen Edge Installer

Official installer for RapidPen Supervisor - deploy AI-powered penetration testing to your edge environment.

## Quick Start

Install RapidPen Supervisor with a single command:

```bash
curl -fsSL https://raw.githubusercontent.com/SecDev-Lab/RapidPen-Edge-Installer/main/install.sh | sudo sh
```

During installation, you'll be prompted for:
- **RapidPen Cloud API Key**: Obtain from [RapidPen Cloud Web UI](https://cloud.rapidpen.app)
- **Base URL** (optional): Default is `https://api.rapidpen.app/api/edge/supervisor`

## Prerequisites

- **Operating System**: Ubuntu 20.04+, Debian 11+, or CentOS Stream 9+
- **Docker Engine**: Version 24.0 or later
- **Root Access**: Installation requires sudo privileges
- **Network**: Internet connection

## Managing the Service

### Start the Service

```bash
sudo systemctl start rapidpen-supervisor
```

### Check Status

```bash
sudo systemctl status rapidpen-supervisor
```

### View Logs

```bash
# Follow live logs
sudo journalctl -u rapidpen-supervisor -f

# View recent logs
sudo journalctl -u rapidpen-supervisor -n 100
```

### Stop the Service

```bash
sudo systemctl stop rapidpen-supervisor
```

### Restart the Service

```bash
sudo systemctl restart rapidpen-supervisor
```

## Uninstallation

Remove RapidPen Supervisor from your system:

```bash
sudo rapidpen-uninstall
```

This will:
- Stop and disable the systemd service
- Remove the Docker container (images are preserved)
- Delete configuration files from `/etc/rapidpen/`
- Delete log files from `/var/log/rapidpen/`
- Remove the uninstall command itself

## Troubleshooting

### Service Won't Start

Check Docker is running:
```bash
sudo systemctl status docker
```

Check service logs:
```bash
sudo journalctl -u rapidpen-supervisor -n 50
```

### Container Not Found

Verify the supervisor container is running:
```bash
docker ps | grep rapidpen-supervisor
```

If not running, check systemd service status:
```bash
sudo systemctl status rapidpen-supervisor
```

### Permission Issues

Ensure the installer was run with sudo:
```bash
# Correct
sudo sh install.sh

# Incorrect
sh install.sh
```

## Security Considerations

- **API Key Security**: The API key is stored in `/etc/rapidpen/supervisor/state.json` with 600 permissions (root only)
- **Docker Socket**: The supervisor mounts `/var/run/docker.sock` to manage operator containers
- **Network Access**: The supervisor communicates with RapidPen Cloud over HTTPS

## Support

- **Issues**: [GitHub Issues](https://github.com/SecDev-Lab/RapidPen-Edge-Installer/issues)

## License

See the [LICENSE file](./LICENSE).
