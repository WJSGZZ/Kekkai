// 虚拟定位：注入结界里运行的软件，让它向系统要定位时拿到 KEKKAI_LAT／KEKKAI_LON。
// 不连系统的定位服务，所以既不弹授权，也拿不到真实位置。
#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>

static CLLocation *fakeLocation(void) {
    const char *lat = getenv("KEKKAI_LAT"), *lon = getenv("KEKKAI_LON");
    if (!lat || !lon) return nil;
    CLLocationCoordinate2D c = CLLocationCoordinate2DMake(atof(lat), atof(lon));
    return [[CLLocation alloc] initWithCoordinate:c altitude:30 horizontalAccuracy:20 verticalAccuracy:20
                                        timestamp:[NSDate date]];
}

static void deliver(CLLocationManager *m) {
    dispatch_async(dispatch_get_main_queue(), ^{
        id<CLLocationManagerDelegate> d = m.delegate;
        if ([d respondsToSelector:@selector(locationManager:didUpdateLocations:)])
            [d locationManager:m didUpdateLocations:@[fakeLocation()]];
    });
}

static void notifyAuth(CLLocationManager *m) {
    dispatch_async(dispatch_get_main_queue(), ^{
        id<CLLocationManagerDelegate> d = m.delegate;
        if ([d respondsToSelector:@selector(locationManagerDidChangeAuthorization:)])
            [d locationManagerDidChangeAuthorization:m];
        if ([d respondsToSelector:@selector(locationManager:didChangeAuthorizationStatus:)])
            [d locationManager:m didChangeAuthorizationStatus:kCLAuthorizationStatusAuthorizedAlways];
    });
}

static void replace(Class c, SEL s, id block) {
    Method m = class_getInstanceMethod(c, s);
    if (m) method_setImplementation(m, imp_implementationWithBlock(block));
}

__attribute__((constructor)) static void install(void) {
    if (!fakeLocation()) return;
    Class c = [CLLocationManager class], meta = object_getClass(c);
    replace(meta, @selector(authorizationStatus), ^CLAuthorizationStatus(id _) { return kCLAuthorizationStatusAuthorizedAlways; });
    replace(meta, @selector(locationServicesEnabled), ^BOOL(id _) { return YES; });
    replace(c, @selector(authorizationStatus), ^CLAuthorizationStatus(id _) { return kCLAuthorizationStatusAuthorizedAlways; });
    replace(c, @selector(accuracyAuthorization), ^CLAccuracyAuthorization(id _) { return CLAccuracyAuthorizationFullAccuracy; });
    replace(c, @selector(location), ^CLLocation *(id _) { return fakeLocation(); });
    replace(c, @selector(requestWhenInUseAuthorization), ^(CLLocationManager *m) { notifyAuth(m); });
    replace(c, @selector(requestAlwaysAuthorization), ^(CLLocationManager *m) { notifyAuth(m); });
    replace(c, @selector(startUpdatingLocation), ^(CLLocationManager *m) { deliver(m); });
    replace(c, @selector(requestLocation), ^(CLLocationManager *m) { deliver(m); });
    replace(c, @selector(stopUpdatingLocation), ^(id _) {});
    replace(c, @selector(startMonitoringSignificantLocationChanges), ^(CLLocationManager *m) { deliver(m); });
}
