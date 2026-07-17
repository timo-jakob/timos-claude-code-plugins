```mermaid
C4Context
    title System Context for the clean fixture
    Person(dev, "Developer", "Maintains the plugin")
    System(fixture, "Clean Fixture", "A Claude Code plugin")
    Rel(dev, fixture, "Maintains")
```
