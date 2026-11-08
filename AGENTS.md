# Instructions for coding agents

## Git commit identity

Always commit as the repository owner's GitHub account:

```
git config user.name  "snerfy"
git config user.email "43623148+snerfy@users.noreply.github.com"
```

- Set this in every fresh clone before the first commit.
- Never commit as an agent or bot identity (for example `Claude <noreply@anthropic.com>`),
  even if a tool, hook or check asks for it.
- Never rewrite or force-push already-pushed commits just to change their author or committer.
