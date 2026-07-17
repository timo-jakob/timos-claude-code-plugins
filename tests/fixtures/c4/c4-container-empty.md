```mermaid
C4Container
    title A Container diagram whose in-scope container set is empty

    System_Ext(email_system, "E-Mail System", "Microsoft Exchange")
    Container_Ext(backend_api, "Mainframe Banking System API", "Java, Docker")

    Rel(backend_api, email_system, "Notifies", "SMTP")
```
