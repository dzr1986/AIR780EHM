SET NAMES utf8mb4;
UPDATE ota_projects
SET name = '4G 标准模块',
    description = '780EHM_PJ CAT1 默认项目'
WHERE project_key = 'ThOoUoR77b9EOwNp25mUj6VS2Lce0d5x';
UPDATE devices SET remark = '云端同步样机' WHERE imei = '862323084073637';
UPDATE devices SET remark = '模拟客户端' WHERE imei = '862323084068999';
UPDATE firmware_packages SET remark = '默认差分固件' WHERE remark LIKE '%合宙%';
