-- Migration 002 : ajout d'une référence produit (idempotente)
ALTER TABLE products ADD COLUMN IF NOT EXISTS sku TEXT UNIQUE;
UPDATE products SET sku = 'SKU-' || lpad(id::text, 5, '0') WHERE sku IS NULL;
