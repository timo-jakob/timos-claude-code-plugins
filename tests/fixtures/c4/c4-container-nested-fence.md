# Container diagram — with an illustrative nested fence

Here is how a `C4Container` block is written (shown inside a four-backtick fence,
so it must NOT be extracted):

````text
```mermaid
C4Container
    Container(fake_example, "Do Not Extract Me", "Java")
```
````

And here is the real diagram:

```mermaid
C4Container
    Container(real_one, "The Real Container", "Java")
```
