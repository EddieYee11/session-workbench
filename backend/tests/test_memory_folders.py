import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from memory_catalog import FOLDERS,folder_of,plain,headline

def test_knowledge_files_land_in_purpose_folders():
    k={'kind':'knowledge'}
    assert folder_of(k,'内网Windows主机_VR串流')=='设备'
    assert folder_of(k,'搜狐视频数据获取_方法论')=='技能'
    assert folder_of(k,'视频号_成片管线与模板')=='创作'
    assert folder_of(k,'Agent系统_工作台与工具链')=='项目'
    assert {f['name'] for f in FOLDERS}>={folder_of({'kind':'fact','category':c}) for c in ('关于我','工作','项目','生活','兴趣','健康','财务')}

def test_preview_is_plain_text_and_facts_get_a_title():
    assert plain('**结构**：根目录 `work/` 见 [索引](a.md)\n- 第二条')=='结构：根目录 work/ 见 索引 第二条'
    assert headline('Eddie 在搜狐的当前年包 24.5 万，由过去几年每年平均涨薪。后面')=='Eddie 在搜狐的当前年包 24.5 万，由…'
