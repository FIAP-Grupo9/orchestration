-- Cria os bancos lógicos e usuários isolados por microsserviço.
-- Cada serviço se conecta apenas ao SEU banco com SEU usuário,
-- preservando o boundary de microsserviço mesmo com instância única.

CREATE DATABASE users_db;
CREATE DATABASE catalog_db;
CREATE DATABASE payments_db;

CREATE USER users_user WITH PASSWORD 'users_pwd';
CREATE USER catalog_user WITH PASSWORD 'catalog_pwd';
CREATE USER payments_user WITH PASSWORD 'payments_pwd';

GRANT ALL PRIVILEGES ON DATABASE users_db    TO users_user;
GRANT ALL PRIVILEGES ON DATABASE catalog_db  TO catalog_user;
GRANT ALL PRIVILEGES ON DATABASE payments_db TO payments_user;

\c users_db
GRANT ALL ON SCHEMA public TO users_user;
ALTER SCHEMA public OWNER TO users_user;

\c catalog_db
GRANT ALL ON SCHEMA public TO catalog_user;
ALTER SCHEMA public OWNER TO catalog_user;

\c payments_db
GRANT ALL ON SCHEMA public TO payments_user;
ALTER SCHEMA public OWNER TO payments_user;
