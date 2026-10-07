"""Small, deliberately buggy exercise. No dependencies or network access."""


def slugify(title: str) -> str:
    return title.strip().lower().replace(" ", "-")
