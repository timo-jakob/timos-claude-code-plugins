```mermaid
C4Container
    title Container diagram for the clean fixture
    Person(dev, "Developer", "Maintains the plugin")
    Container_Boundary(fixture, "Clean Fixture") {
        %% A Claude Code plugin ships as source, not a deployable container image.
    }
    Rel(dev, fixture, "Maintains")
```
