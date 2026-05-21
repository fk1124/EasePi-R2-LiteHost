if [ -r /etc/easepi-r2-desktop.env ]; then
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    echo "Tip: run 'desktop' to start the HDMI desktop session with startx."
fi
