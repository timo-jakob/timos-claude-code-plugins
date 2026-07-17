```mermaid
C4Container
    Container_Boundary(c1, "Internet Banking") {
        Container(web_app, "Web Application", "Java, Spring MVC")
        Container(web_app, "A Second Web Application With A Reused Alias", "Java")
    }
```
