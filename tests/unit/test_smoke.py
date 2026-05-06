"""Smoke test — verifies the package tree imports cleanly.

Real tests arrive in Wave 2+. This exists so pytest doesn't exit 5
(no tests collected) and the pre-push hook stays happy on bootstrap.
"""


def test_packages_import() -> None:
    import packages.core
    import packages.courses
    import packages.shared  # noqa: F401
