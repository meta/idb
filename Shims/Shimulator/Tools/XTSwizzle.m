/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "XTSwizzle.h"

#import <Foundation/Foundation.h>

void XTSwizzleClassSelectorForFunction(Class cls, SEL sel, IMP newImp) __attribute__((no_sanitize("nullability-arg")))
{
  Class clscls = object_getClass((id)cls);
  Method originalMethod = class_getClassMethod(cls, sel);

  NSString *selectorName = [[NSString alloc] initWithFormat:
                            @"__%s_%s",
                            class_getName(cls),
                            sel_getName(sel)];
  SEL newSelector = NSSelectorFromString(selectorName);

  class_addMethod(clscls, newSelector, newImp, method_getTypeEncoding(originalMethod));
  Method replacedMethod = class_getClassMethod(cls, newSelector);
  method_exchangeImplementations(originalMethod, replacedMethod);
}

void XTSwizzleSelectorForFunction(Class cls, SEL sel, IMP newImp)
{
  Method originalMethod = class_getInstanceMethod(cls, sel);
  const char *typeEncoding = method_getTypeEncoding(originalMethod);

  NSString *selectorName = [[NSString alloc] initWithFormat:
                            @"__%s_%s",
                            class_getName(cls),
                            sel_getName(sel)];
  SEL newSelector = NSSelectorFromString(selectorName);

  class_addMethod(cls, newSelector, newImp, typeEncoding);

  Method newMethod = class_getInstanceMethod(cls, newSelector);
  if (class_addMethod(cls, sel, newImp, typeEncoding)) {
    class_replaceMethod(cls, newSelector, method_getImplementation(originalMethod), typeEncoding);
  } else {
    method_exchangeImplementations(originalMethod, newMethod);
  }
}
