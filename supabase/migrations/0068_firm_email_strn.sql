-- Firm letterhead: email + STRN (address already exists)
alter table companies add column if not exists address text;
alter table companies add column if not exists email text;
alter table companies add column if not exists strn text;
