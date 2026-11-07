import logging
import logging.config
import datetime
import re
import unicodedata


"""北京时间（UTC+8）"""
BEIJING_TZ = datetime.timezone(datetime.timedelta(hours=8))


# --------------------------------------------------------------------------- #
# 控制台输出优化
# --------------------------------------------------------------------------- #

"""是否启用 Emoji（Windows PowerShell 建议关闭以避免重影）"""
ENABLE_EMOJI = True


def strip_emoji(text: str) -> str:
    """移除字符串中的 Emoji 字符（保留变体选择符前的字符）"""
    if not text:
        return text
    result = []
    for ch in text:
        cat = unicodedata.category(ch)
        # 移除 Emoji 类别：So (Symbol, other) 中大部分是 Emoji
        if cat == "So":
            continue
        # 移除变体选择符 U+FE0F 等
        if ch == "\ufe0f":
            continue
        result.append(ch)
    return "".join(result)


def display_width(text: str) -> int:
    """计算字符串在终端中的显示宽度（全角字符算 2 列，半角算 1 列）"""
    if not text:
        return 0
    width = 0
    for ch in text:
        if unicodedata.east_asian_width(ch) in ("F", "W", "A"):
            width += 2  # 全角字符
        else:
            width += 1  # 半角字符
    return width


def pad_text(text: str, width: int, align: str = "left", fillchar: str = " ", truncate: bool = True) -> str:
    """
    按显示宽度填充字符串，使其达到指定宽度。
    可选：超长时截断并加省略号。

    Args:
        text: 要填充的文本
        width: 目标显示宽度
        align: 对齐方式 ("left", "right", "center")
        fillchar: 填充字符
        truncate: 超长时是否截断（默认 True）

    Returns:
        填充后的字符串
    """
    current = display_width(text)
    if current >= width:
        if truncate and current > width:
            # 截断：保留到 width-2，加 ".."
            # 从右往左逐步移除字符，直到宽度合适
            truncated = text
            while display_width(truncated) > width - 2 and len(truncated) > 0:
                truncated = truncated[:-1]
            return truncated + ".."
        return text

    padding = width - current
    if align == "left":
        return text + fillchar * padding
    elif align == "right":
        return fillchar * padding + text
    else:  # center
        left = padding // 2
        right = padding - left
        return fillchar * left + text + fillchar * right


LEVEL_TAGS = {
    "DEBUG": "[D]",
    "INFO": "[I]",
    "WARNING": "[W]",
    "ERROR": "[E]",
    "CRITICAL": "[C]",
}

"""日志脱敏规则：抹掉 GLaDOS 会话字段与 Bearer 凭证，避免 Cookie 泄漏到 Actions 日志"""
_SECRET_PATTERNS = (
    (re.compile(r"\b((?:koa|gld):[A-Za-z0-9_.-]+=)([^;\s\"']+)"), r"\1[REDACTED]"),
    (re.compile(r"(\"cookie\"\s*:\s*\")([^\"]+)(\")", re.IGNORECASE), r"\1[REDACTED]\3"),
    (re.compile(r"(Bearer\s+)([A-Za-z0-9._~+/=-]+)", re.IGNORECASE), r"\1[REDACTED]"),
)


def redact(text):
    """对日志文本做敏感信息脱敏"""
    if not isinstance(text, str) or not text:
        return text
    for pattern, replacement in _SECRET_PATTERNS:
        text = pattern.sub(replacement, text)
    return text


class AlignedFormatter(logging.Formatter):
    """日志级别显示为固定 3 字符短标签（[W]/[I]/[E]...）；时间用北京时间，并统一脱敏"""

    def formatTime(self, record, datefmt=None):
        """北京时间。strftime 不认 %f，这里统一走 datetime 以保证时区准确"""
        dt = datetime.datetime.fromtimestamp(record.created, tz=BEIJING_TZ)
        return dt.strftime(datefmt or "%Y-%m-%d %H:%M:%S")

    def format(self, record):
        # 复制一份再改写：直接改 record 会让后续 handler 读到已带标签的 levelname（输出变成 "[["），
        # 也会污染共享的 LogRecord。makeLogRecord 只做浅拷贝，开销可忽略。
        copy = logging.makeLogRecord(record.__dict__)
        copy.levelname = LEVEL_TAGS.get(record.levelname, f"[{record.levelname[0]}]")
        msg = record.msg
        # 可选：移除 Emoji 避免 Windows PowerShell 重影
        if not ENABLE_EMOJI:
            msg = strip_emoji(msg)
        copy.msg = redact(msg)
        if record.args:
            if isinstance(record.args, tuple):
                copy.args = tuple(redact(arg) if isinstance(arg, str) else arg for arg in record.args)
            elif isinstance(record.args, dict):
                copy.args = {k: redact(v) if isinstance(v, str) else v for k, v in record.args.items()}
        return super().format(copy)


LOGGING_CONFIG = {
    "version": 1,
    "disable_existing_loggers": False,
    "formatters": {
        "standard": {
            "()": "logging_config.AlignedFormatter",
            "format": "%(asctime)s - %(levelname)s - %(message)s",
            "datefmt": "%Y-%m-%d %H:%M:%S",
        },
    },
    "handlers": {
        "console": {
            "class": "logging.StreamHandler",
            "formatter": "standard",
            "level": "INFO",
        },
    },
    "root": {
        "handlers": ["console"],
        "level": "INFO",
    },
}


def init_logger():
    """初始化日志"""
    logging.config.dictConfig(LOGGING_CONFIG)
    return logging.getLogger()
