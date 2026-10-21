# Base CI Provider Interface
# Shared utilities and base class for CI providers

# Re-export create_obj from core_utils for backward compatibility
from core_utils import create_obj


class Build:
    """Represents a CI build result."""

    def __init__(self, build_id, title, url, status, timestamp, author):
        self.id = build_id
        self.title = title
        self.url = url
        self.status = status
        self.timestamp = timestamp
        self.author = author


def create_build(build_id, title, url, status, timestamp, author):
    """Factory function to create Build objects."""
    return Build(build_id, title, url, status, timestamp, author)
