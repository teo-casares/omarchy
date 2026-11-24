# GNOME Keyring Secret Service backport

GNOME Keyring 51.1 can exit when a request reaches Secret Service before the daemon has registered the D-Bus client. This optional package adds the two changes from [GNOME Keyring MR 112](https://gitlab.gnome.org/GNOME/gnome-keyring/-/merge_requests/112), through commit `8fcdeffe67ae8c1600eae9637816acbf73f66b81`. They register a missing client on demand and make a failed session negotiation return a D-Bus error. [MR 119](https://gitlab.gnome.org/GNOME/gnome-keyring/-/merge_requests/119) proposes registering clients on the D-Bus worker thread with a mutex. This backport uses MR 112 to keep client registration on the main thread.

The recipe retains Arch's runtime dependencies, Cinnamon autostart patch and install hook. Pacman treats `1:51.1-1.1` as an upgrade from the stock `1:51.1-1`. A later stock release such as `1:51.1-2` supersedes the backport normally.

## Build and install

From this directory on Arch or Arch Linux ARM, run the build as your normal user with `base-devel` available.

```bash
makepkg --syncdeps
```

The build checks the release tarball and both patches and runs the upstream Secret Service D-Bus suite. On the Surface Laptop Ultra, the resulting aarch64 package passed all 17 cases in that suite. The packaged daemon also passed an AES session store, lookup and clear with disposable state. PAM login and the crash frequency in a live desktop session were outside that test.

If your installed package is `1:51.1-1`, install the built package during a maintenance window. On aarch64 the command is:

```bash
sudo pacman -U ./gnome-keyring-1:51.1-1.1-aarch64.pkg.tar.xz
```

Save your work and log out and back in when ready to start the new daemon. To return to the stock package, run `sudo pacman -S extra/gnome-keyring` and start a new login session.
