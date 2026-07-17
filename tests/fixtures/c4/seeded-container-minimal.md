# Container Diagram

The deployable units that make up **Libthing**, seeded from detected
structure. Each `Container(...)` entry follows the c4/v1 declared-container
shape (see ARCHITECTURE.md) so the maintenance pipeline can compare it against
the code. Refine labels, technologies, and relationships as needed.

```mermaid
C4Container
    title Container diagram for Libthing

    Person(user, "User", "Uses Libthing")

    Container_Boundary(libthing_boundary, "Libthing") {
        Container(libthing, "Libthing CLI", "Python 3.12")
    }

    Rel(user, libthing, "Uses")
```
