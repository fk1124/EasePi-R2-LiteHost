# Scripts

LiteHost keeps only the helpers used by native Armbian minimal builds:

```text
armbian-patch-guard.sh  temporarily disables known bad upstream Armbian patches
sync-root-scripts.sh    optionally syncs EasePi-R2 root helper scripts into the overlay
```

The public build entry point is `build-image.sh`.
