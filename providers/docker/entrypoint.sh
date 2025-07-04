#!/bin/bash
set -e

# Ensure proper ownership of mounted Claude directory if it exists
if [ -d "/home/vagrant/.claude" ]; then
    chown -R vagrant:$(id -gn vagrant) /home/vagrant/.claude || true
    chmod -R 755 /home/vagrant/.claude || true
fi

# Run shell setup if config exists
if [ -f /tmp/vm-config.json ]; then
    echo "📄 Found config file, setting up shell..."
    /usr/local/bin/setup-shell.sh
else
    echo "⚠️  No config file found at /tmp/vm-config.json"
fi

# Start supervisor, which will in turn start all configured services.
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf