# sp_TexasHoldEm_Public

This is the hostile-user deployment of the T-SQL Texas Hold 'Em game. It is a
separate implementation from `sp_TexasHoldEm_Codex`; both can be installed in
the same database, and the historical Codex version remains unchanged.

## Security boundary

The installer creates:

- `dbo.sp_TexasHoldEm_Public`, the only object players execute;
- a `TexasHoldEm_Public` schema containing protected permanent state tables;
- a certificate and certificate-mapped user used to decrypt hole cards only
  while the signed procedure runs; and
- a `TexasHoldEm_Public_Players` database role with `EXECUTE` on the procedure
  and explicit denials on the state schema.

The procedure does not use `EXECUTE AS OWNER`. Calls made inside caller-owned
transactions are rejected, state changes use a protected row lock, `RESET` is
restricted to database administrators, lobby calls do not wait on a server
worker, abandoned spectator state and old logs are bounded, and player names
are immutable and restricted to display-safe characters.

This boundary protects against users who have only `CONNECT` plus membership in
`TexasHoldEm_Public_Players`. It does not protect against `db_owner`, server
administrators, object owners, or users allowed to alter the procedure, schema,
tables, certificate, or permissions.

The certificate private-key password appears in the published installer by
design; possession of that string does not grant certificate access. SQL Server
still requires `CONTROL` on the certificate, which the player role is never
given. The signed procedure temporarily contributes that one permission without
impersonating the database owner.

## Install and grant access

Run `sp_TexasHoldEm.sql` as the database administrator. Create the public
contained user separately, using a strong generated password that is not kept
in source control, and add only that user to the game role:

```sql
CREATE USER [YourPublicUser]
    WITH PASSWORD = '<strong-generated-password>';
GO

ALTER ROLE TexasHoldEm_Public_Players ADD MEMBER [YourPublicUser];
GO
```

Do not add the public user to `db_datareader`, `db_datawriter`, `db_ddladmin`,
`db_owner`, or a role with `VIEW DATABASE STATE`. Do not grant it permissions
on the certificate or the `TexasHoldEm_Public` schema.

Players join and poll from one connection:

```sql
EXEC dbo.sp_TexasHoldEm_Public @PlayerName = N'Ada';
EXEC dbo.sp_TexasHoldEm_Public @Action = 'STATUS';
EXEC dbo.sp_TexasHoldEm_Public @Action = 'CALL';
```

## Required Azure isolation

A direct SQL login is not a general-purpose sandbox. Even without object
permissions, a hostile login can submit its own expensive queries, create and
fill temporary tables, use `WAITFOR`, open many connections, and consume the
database's CPU, workers, log, and tempdb resources outside this procedure.

Host this in a disposable Azure SQL database and logical server containing no
other data or workloads. Use a deliberately constrained service objective and
budget, narrowly scoped firewall rules, connection and resource monitoring,
alerts, credential rotation, and a tested kill switch. Assume published shared
credentials will be automated against immediately.

A shared login also cannot prove that four connections represent four people.
One person can occupy multiple seats, collude with themselves, or reconnect
under a new connection identity to receive another starting bankroll. An OUT
row is retained for the life of its game so an idle connection does not regain
chips, but a shared credential provides no durable human identity across
reconnections. Use individual Microsoft Entra/database identities or put an
authenticated application/API in front of SQL when one-human-one-seat or
one-bankroll-per-human enforcement matters.

The waiting list retains at most 60 spectators in addition to the four seats.
When it is full, a new join evicts the stalest spectator instead of permanently
locking out newcomers. A hostile client can still churn that queue or exhaust
connection and compute limits; the database isolation, monitoring, and kill
switch above remain required.

The game uses fake QueryBucks and is not designed for money or prizes.
