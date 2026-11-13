"""PyInstaller entry point for the 47DR AWG / scope host GUI (same as: cd tools && py -m awg_gui)."""
import sys

from awg_gui.__main__ import main

if __name__ == "__main__":
    sys.exit(main())
