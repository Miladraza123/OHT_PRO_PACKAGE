-- Terms & Conditions on Quotations / Service Quotations, with a per-firm default
alter table companies add column if not exists quotation_terms text;
alter table quotations add column if not exists terms text;
alter table service_quotations add column if not exists terms text;
