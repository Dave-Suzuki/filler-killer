"""fk — one entrypoint: sync, dashboard, listen."""

import argparse
import sys
import webbrowser


def _cmd_sync(args) -> int:
    from fillerkiller.store.db import connect
    from fillerkiller.sync import default_source, sync_meetings

    try:
        source = default_source(
            force_api=getattr(args, "api", False),
            legacy=getattr(args, "legacy_api", False),
        )
    except Exception as e:
        print(f"sync failed: {e}", file=sys.stderr)
        return 1
    conn = connect()
    try:
        stats = sync_meetings(conn, source)
    except Exception as e:
        print(f"sync failed: {e}", file=sys.stderr)
        return 1
    finally:
        conn.close()
    line = (
        f"synced: {stats['added']} new, {stats['updated']} updated, "
        f"{stats['skipped']} unchanged"
    )
    if stats.get("reattributed"):
        line += f", {stats['reattributed']} re-attributed (FK_MY_NAME)"
    print(line)
    return 0


def _cmd_dashboard(args) -> int:
    import socket

    import uvicorn

    from fillerkiller import config
    from fillerkiller.dashboard.app import create_app

    with socket.socket() as probe:
        if probe.connect_ex((config.DASHBOARD_HOST, config.DASHBOARD_PORT)) == 0:
            print(
                f"error: something is already serving on port {config.DASHBOARD_PORT} — "
                "probably an old fk dashboard from before an update, which would show "
                "stale pages.\nStop it first:\n"
                f"  /usr/sbin/lsof -ti :{config.DASHBOARD_PORT} | xargs kill\n"
                "then run fk dashboard again.",
                file=sys.stderr,
            )
            return 1

    if not args.no_sync:
        try:
            _cmd_sync(argparse.Namespace(api=False))
        except Exception as e:  # dashboard should still open on stale data
            print(f"warning: Granola sync failed ({e}); showing existing data", file=sys.stderr)

    url = f"http://{config.DASHBOARD_HOST}:{config.DASHBOARD_PORT}"
    print(f"dashboard: {url}")
    if not args.no_browser:
        webbrowser.open(url)
    uvicorn.run(create_app(), host=config.DASHBOARD_HOST, port=config.DASHBOARD_PORT)
    return 0


def _cmd_listen(args) -> int:
    if sys.platform != "darwin":
        print("fk listen uses Apple's Speech framework and only runs on macOS", file=sys.stderr)
        return 1
    if args.no_menubar:
        from fillerkiller.realtime.listener import run_terminal

        return run_terminal(label=args.label)
    from fillerkiller.realtime.menubar import run_menubar

    return run_menubar(label=args.label)


def _cmd_doctor(args) -> int:
    from fillerkiller.doctor import run_doctor

    return run_doctor()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="fk", description="filler-killer")
    sub = parser.add_subparsers(dest="command", required=True)

    p_sync = sub.add_parser("sync", help="pull Granola meetings and analyze them")
    p_sync.add_argument("--api", action="store_true",
                        help="force the official Granola API (needs GRANOLA_API_KEY; "
                        "used automatically when the key is set)")
    p_sync.add_argument("--legacy-api", action="store_true", dest="legacy_api",
                        help="unofficial API with the desktop app's token "
                        "(pre-encryption Granola installs only)")
    p_sync.set_defaults(func=_cmd_sync)

    p_dash = sub.add_parser("dashboard", help="sync, then serve the local dashboard")
    p_dash.add_argument("--no-sync", action="store_true", help="skip the Granola sync")
    p_dash.add_argument("--no-browser", action="store_true", help="don't open a browser")
    p_dash.set_defaults(func=_cmd_dashboard)

    p_doctor = sub.add_parser("doctor", help="check setup and say what to fix")
    p_doctor.set_defaults(func=_cmd_doctor)

    p_listen = sub.add_parser("listen", help="real-time filler counter (macOS)")
    p_listen.add_argument("--no-menubar", action="store_true",
                          help="print to the terminal instead of the menu bar")
    p_listen.add_argument("--label", default=None, help="session label for the dashboard")
    p_listen.set_defaults(func=_cmd_listen)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
