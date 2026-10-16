"""The check application is a file of the overlay, not a package: its
directory goes first on the import path."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..",
                                "overlay", "usr", "share", "keel-lnpp", "app"))
