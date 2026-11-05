#include <jni.h>

extern int askme_backend_api_version(void);
extern int askme_backend_initialize(void);

JNIEXPORT jint JNICALL
Java_com_example_askme_MainActivity_nativeBackendApiVersion(JNIEnv *env, jobject thiz) {
    (void) env;
    (void) thiz;
    return (jint) askme_backend_api_version();
}

JNIEXPORT jint JNICALL
Java_com_example_askme_MainActivity_nativeBackendInitialize(JNIEnv *env, jobject thiz) {
    (void) env;
    (void) thiz;
    return (jint) askme_backend_initialize();
}
